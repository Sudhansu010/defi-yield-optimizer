// scripts/deploy.js
//
// Deploys the DeFi Yield Optimizer to Arc testnet.
//
// Usage:
//   npx hardhat run scripts/deploy.js --network arcTestnet
//
// Before running:
//   1. Get testnet USDC from https://faucet.circle.com (select "Arc Testnet")
//   2. Set PRIVATE_KEY and ARC_TESTNET_RPC_URL in a .env file (see hardhat.config.js)
//   3. Update USDC_ADDRESS below with Arc testnet's USDC contract address (see docs.arc.network)

const hre = require("hardhat");

// TODO: replace with the real Arc testnet USDC address from docs.arc.network
const USDC_ADDRESS = process.env.ARC_TESTNET_USDC || "0x0000000000000000000000000000000000000000";

// Seed reserve (in USDC, 6 decimals) sent to each mock strategy so it can simulate
// yield payouts during the demo. Adjust based on how much testnet USDC you have.
const RESERVE_PER_STRATEGY = hre.ethers.parseUnits("50", 6);

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);

  if (USDC_ADDRESS === "0x0000000000000000000000000000000000000000") {
    throw new Error("Set USDC_ADDRESS / ARC_TESTNET_USDC to the real Arc testnet USDC address first.");
  }

  // 1. Deploy the vault
  const Vault = await hre.ethers.getContractFactory("YieldOptimizerVault");
  const vault = await Vault.deploy(USDC_ADDRESS);
  await vault.waitForDeployment();
  console.log("YieldOptimizerVault deployed to:", vault.target);

  // 2. Deploy four strategy adapters representing the protocols mentioned in the pitch
  const Strategy = await hre.ethers.getContractFactory("MockYieldStrategy");

  const strategyConfigs = [
    { name: "Aave USDC Pool", apyBps: 380 },      // 3.80%
    { name: "Compound USDC Pool", apyBps: 410 },  // 4.10%
    { name: "Uniswap V3 USDC/USDT LP", apyBps: 620 }, // 6.20% (higher, more volatile)
    { name: "Curve 3pool", apyBps: 450 },         // 4.50%
  ];

  const deployedStrategies = [];
  for (const cfg of strategyConfigs) {
    const strategy = await Strategy.deploy(
      cfg.name,
      USDC_ADDRESS,
      vault.target,
      deployer.address, // keeper = deployer for the demo; swap for a bot/oracle in prod
      cfg.apyBps
    );
    await strategy.waitForDeployment();
    console.log(`${cfg.name} deployed to:`, strategy.target);
    deployedStrategies.push(strategy);
  }

  // 3. Register each strategy with the vault
  for (const strategy of deployedStrategies) {
    const tx = await vault.addStrategy(strategy.target);
    await tx.wait();
  }
  console.log("All strategies registered with the vault.");

  // 4. Fund each strategy's yield reserve so accrueYield() has something real to pay out
  const usdc = await hre.ethers.getContractAt(
    ["function transfer(address,uint256) returns (bool)"],
    USDC_ADDRESS,
    deployer
  );
  for (const strategy of deployedStrategies) {
    const tx = await usdc.transfer(strategy.target, RESERVE_PER_STRATEGY);
    await tx.wait();
  }
  console.log("Seeded yield reserves for all strategies.");

  console.log("\nDeployment summary:");
  console.log("  Vault:      ", vault.target);
  deployedStrategies.forEach((s, i) => console.log(`  ${strategyConfigs[i].name}:`, s.target));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
