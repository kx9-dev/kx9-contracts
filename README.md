# KX-9 Contracts

Solidity Shield vaults and factory with operator limits, supervised approvals and local-chain tests.

[Website](https://kx9.tech) · [Command app](https://app.kx9.tech) · [Documentation](https://github.com/kx9-dev/kx9-docs) · [Releases](https://github.com/kx9-dev/kx9-contracts/releases) · [Contact](mailto:dev@kx9.tech)

**Source release 0.1.0.** MIT-licensed source, not an audit or a claim of
active trading. Robinhood mainnet chain ID: **4663**. KX-9 is not affiliated
with Robinhood Markets or NVIDIA Corporation. Physical AI · NVDA is a
rule-based stock-token allocation strategy, not an NVIDIA AI service.

## Contents
- KX9Shield: operator-owned vault, modes, limits, permissions and execution.
- KX9ShieldFactory: per-operator unit creation and Shield discovery.
- Local mocks and the supplied contract flow tests.
- Explicit deployment CLI; no automatic mainnet deployment.

## Build and test
Requires Node.js 22+.

```sh
npm ci
npm run compile
npm test
```

Compilation generates ABI/bytecode JSON in `out/`. Tests use disposable local
Anvil accounts and synthetic local fixtures, not funded wallets.
The compiler is pinned to Solidity 0.8.24 with the Shanghai target.
CLI and compiler inputs are in this repository; generated output is excluded
from source commits and can be rebuilt.

## Safety model and limitations
Only the operator changes modes, limits, allowlists and supervised approvals.
Only the configured executor may call execute. The Shield enforces router
allowlists, input/output asset permissions, daily/trade caps, cooldown and
oracle-based slippage.

Supervised approvals are single-use and bounded by proposal ID, USD cap and
deadline. Autonomous calls do not consume proposal IDs, so the backend must
prevent duplicate signing and replay after a restart.

Passing local tests is not an audit. No deployed address or mainnet readiness
is implied. Verify the oracle, sequencer policy, assets, router and executor
before funding. Stock-token rights depend on the actual issuer and jurisdiction.
The owner will deploy the KX9 token separately.

## Deployment
Read `scripts/deploy.mjs` and [.env.example](.env.example). It rejects a chain
other than 4663. Signing and broadcast require explicit private environment
configuration and authorization. Never commit deployment keys or private RPCs.
Do not run deployment as part of CI or a pull request.

## Repositories
| Repository | Responsibility |
| --- | --- |
| [kx9-web](https://github.com/kx9-dev/kx9-web) | KX-9 landing page and wallet-connected Command app for Robinhood mainnet. |
| [kx9-core](https://github.com/kx9-dev/kx9-core) | Wallet-authenticated Core API, deterministic trading rules, risk checks and mainnet execution controls. |
| [kx9-contracts](https://github.com/kx9-dev/kx9-contracts) | Solidity Shield vaults and factory with operator limits, supervised approvals and local-chain tests. |
| [kx9-docs](https://github.com/kx9-dev/kx9-docs) | Architecture, operating flows, OpenAPI specification, security boundaries and mainnet configuration. |

## Contributing and security
Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Maintainer contact: **dev@kx9.tech**.

## License
[MIT](LICENSE). Third-party dependencies and externally loaded fonts/libraries
retain their respective licenses; see [NOTICE](NOTICE).
