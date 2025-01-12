// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./OrderCreator.sol";

/**
 * @title Factory for deterministic deployment of OrderCreator contracts
 * @dev Uses CREATE2 for predictable contract address deployment independent of deployer.
 */
contract OrderCreatorFactory {
    event OrderCreatorDeployed(address indexed deployedAddress, address indexed receiver);

    /**
     * @notice Deploys a new OrderCreator contract with CREATE2.
     * @param receiver Address to receive GNO.
     * @return deployedAddress Address of the deployed contract.
     */
    function deployOrderCreator(address receiver) external returns (address deployedAddress) {
        require(receiver != address(0), "Receiver address cannot be zero");

        bytes32 salt = keccak256(abi.encodePacked(receiver));
        bytes memory bytecode = abi.encodePacked(type(OrderCreator).creationCode, abi.encode(receiver));

        assembly {
            deployedAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(deployedAddress)) { revert(0, 0) }
        }

        emit OrderCreatorDeployed(deployedAddress, receiver);
    }

    /**
     * @notice Computes the deterministic address for an OrderCreator contract.
     * @param receiver Address to receive GNO.
     * @return predictedAddress Predicted address of the deployed contract.
     */
    function computeAddress(address receiver) external view returns (address predictedAddress) {
        require(receiver != address(0), "Receiver address cannot be zero");
        bytes32 salt = keccak256(abi.encodePacked(receiver));
        bytes memory bytecode = abi.encodePacked(type(OrderCreator).creationCode, abi.encode(receiver));
        predictedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)))))
        );
    }
}
