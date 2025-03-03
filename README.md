# Circles Backing & Factory

## Overview

This repository contains smart contracts for Circles Backing and Circles Backing Factory. The Circles Backing contract facilitates the backing of USDC and inflationary Circles (CRC) using Cowswap and Balancer Liquidity Bootstrapping Pools (LBP). The Circles Backing Factory is responsible for deploying Circles Backing instances and managing supported backing assets.

## Contracts

### CirclesBacking.sol
- Manages the backing process for inflationary CRC and USDC.
- Interacts with Cowswap for order execution.
- Creates an LBP upon order fulfillment.
- Holds Balancer Pool Tokens (BPT) for one year before allowing the backer to release them.

### CirclesBackingFactory.sol
- Deploys new Circles Backing instances.
- Manages supported backing assets and global Balancer Pool Token release.
- Facilitates the creation of LBPs.
- Ensures only `HubV2` human avatars can back their personal CRC.

## Getting Started

### Prerequisites
- Install [Foundry](https://book.getfoundry.sh/) for Solidity development.
- Ensure you have an Ethereum node or use a forked network for testing.

### Installation

Clone the repository and install dependencies:

```sh
git clone <repository-url>
cd <project-folder>
forge install
```

### Compilation

Compile the smart contracts using Foundry:

```sh
forge build
```

### Running Tests

Before running tests, make sure to set up the `GNOSIS_RPC` environment variable in your `.env` file for forked testing.
Run the test suite with Foundry:

```sh
forge test
```

To run a specific test:

```sh
forge test --match-test test_CreateLBP
```

### Coverage

To check the test coverage of the project, run the following command:

```sh
forge coverage --no-match-coverage "test|script"
```

The `--no-match-coverage "test|script"` flag ensures that only relevant files coverage is measured.

## Project Structure

```
├── src/                    # Smart contract source code
│   ├── CirclesBacking.sol  # Circles Backing contract
│   ├── CirclesBackingFactory.sol # Factory contract
├── test/                   # Foundry tests
│   ├── CirclesBackingFactory.t.sol # Tests for factory and backing
├── script/                 # Deployment scripts
│   ├── Deploy.s.sol        # Deployment script for Foundry
└── foundry.toml            # Foundry configuration file
```
