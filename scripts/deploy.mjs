// Deploy KX9ShieldFactory to Robinhood Chain.
// Usage:
//   PRIVATE_KEY=0x... ORACLE=0x... EXECUTOR=0x... ROUTERS=0xRouter1,0xRouter2 \
//   KX9_TOKEN=0x... AUTONOMOUS_MIN=1000 node scripts/deploy.mjs
// Optional: RPC_URL (default: Robinhood Chain public mainnet RPC).
import { ethers } from 'ethers';
import fs from 'fs';

const RPC_URL = process.env.RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const CHAIN_ID = 4663n;

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`Missing ${k}`); process.exit(1); } return v; };
const addr = (k, optional = false) => {
  const v = process.env[k];
  if (!v) { if (optional) return ethers.ZeroAddress; console.error(`Missing ${k}`); process.exit(1); }
  if (!ethers.isAddress(v)) { console.error(`${k} is not an address: ${v}`); process.exit(1); }
  return ethers.getAddress(v);
};

const provider = new ethers.JsonRpcProvider(RPC_URL);
const net = await provider.getNetwork();
if (net.chainId !== CHAIN_ID && !process.env.ALLOW_OTHER_CHAIN) {
  console.error(`Connected to chain ${net.chainId}, expected Robinhood Chain (${CHAIN_ID}). Set ALLOW_OTHER_CHAIN=1 to override.`);
  process.exit(1);
}
const wallet = new ethers.Wallet(need('PRIVATE_KEY'), provider);

const oracle = addr('ORACLE');
const executor = addr('EXECUTOR');
const token = addr('KX9_TOKEN', true);
const autonomousMin = ethers.parseEther(process.env.AUTONOMOUS_MIN || '0');
const routers = (process.env.ROUTERS || '').split(',').map((s) => s.trim()).filter(Boolean).map((r) => {
  if (!ethers.isAddress(r)) { console.error(`Bad router ${r}`); process.exit(1); } return ethers.getAddress(r);
});
if (!routers.length) { console.error('Set ROUTERS to at least one DEX router address'); process.exit(1); }

const art = JSON.parse(fs.readFileSync(new URL('../out/KX9ShieldFactory.json', import.meta.url)));
console.log(`Deployer ${wallet.address} on chain ${net.chainId}`);
console.log(`Balance ${ethers.formatEther(await provider.getBalance(wallet.address))} ETH`);

const factory = await new ethers.ContractFactory(art.abi, art.bytecode, wallet)
  .deploy(oracle, token, autonomousMin, executor, routers);
console.log(`Deploying… tx ${factory.deploymentTransaction().hash}`);
await factory.waitForDeployment();
const address = await factory.getAddress();
console.log(`KX9ShieldFactory deployed at ${address}`);

fs.mkdirSync(new URL('../deployments/', import.meta.url), { recursive: true });
const record = { chainId: Number(net.chainId), factory: address, oracle, executor, kx9Token: token,
  autonomousMinBalance: autonomousMin.toString(), routers, deployedAt: new Date().toISOString(),
  explorer: `https://robinhoodchain.blockscout.com/address/${address}` };
fs.writeFileSync(new URL('../deployments/robinhood-mainnet.json', import.meta.url), JSON.stringify(record, null, 2));
console.log('Saved deployments/robinhood-mainnet.json. Paste the factory address into KX9_CONFIG in app.html.');
