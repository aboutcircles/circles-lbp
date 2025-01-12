// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IGetUid {
    function getUid(
        address sellToken,
        address buyToken,
        address receiver,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData,
        uint256 feeAmount,
        bool isSell,
        bool partiallyFillable
    ) external view returns (bytes32 hash, bytes memory encoded);
}

interface ICowswapSettlement {
    function setPreSignature(bytes calldata orderUid, bool signed) external;
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

contract OrderCreator {
    address public constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address public constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address public constant GET_UID_CONTRACT = 0xCA51403B524dF7dA6f9D6BFc64895AD833b5d711;
    address public constant COWSWAP_SETTLEMENT_CONTRACT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant RECEIVER = 0x6BF173798733623cc6c221eD52c010472247d861;
    address public constant VAULT_RELAY = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    uint256 public constant WXDAI_DECIMALS = 1e18;
    uint256 public constant TRADE_AMOUNT = 100000000000000000; // 0.1 wxDAI in 18 decimals
    uint32 public constant VALID_TO = uint32(1894006860);

    bytes public storedOrderUid;

    event OrderCreated(bytes32 orderHash);
    event GnoTransferred(uint256 amount, address receiver);

    string public constant preAppData =
        '{"version":"1.1.0","appCode":"Zeal powered by Qantura","metadata":{"hooks":{"version":"0.1.0","post":[{"target":"';
    string public constant postAppData = '","callData":"0xbb5ae136","gasLimit":"200000"}]}}}'; // Updated calldata for checkOrderFilledAndTransfer

    function addressToString(address _addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";

        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }

        return string(str);
    }

    function getAppData(address _newAccount) public pure returns (bytes32) {
        string memory _newAccountStr = addressToString(_newAccount);
        string memory _appDataStr = string.concat(preAppData, _newAccountStr, postAppData);
        return keccak256(bytes(_appDataStr));
    }

    function getAppDataString(address _newAccount) public pure returns (string memory) {
        string memory _newAccountStr = addressToString(_newAccount);
        return string.concat(preAppData, _newAccountStr, postAppData);
    }

    function createOrder() external {
        // Approve wxDAI to Vault Relay contract
        IERC20(WXDAI).approve(VAULT_RELAY, TRADE_AMOUNT);

        // Generate appData dynamically
        bytes32 appData = getAppData(address(this));

        // Generate order UID using the "getUid" contract
        IGetUid getUidContract = IGetUid(GET_UID_CONTRACT);

        (bytes32 orderDigest,) = getUidContract.getUid(
            WXDAI,
            GNO,
            address(this), // Use contract address as the receiver
            TRADE_AMOUNT,
            1, // Determined by off-chain logic or Cowswap solvers
            VALID_TO, // ValidTo timestamp
            appData,
            0, // FeeAmount
            true, // IsSell
            false // PartiallyFillable
        );

        // Construct the order UID
        bytes memory orderUid = abi.encodePacked(orderDigest, address(this), uint32(VALID_TO));

        // Store the order UID
        storedOrderUid = orderUid;

        // Place the order using "setPreSignature"
        ICowswapSettlement cowswapSettlement = ICowswapSettlement(COWSWAP_SETTLEMENT_CONTRACT);
        cowswapSettlement.setPreSignature(orderUid, true);

        // Emit event with the order UID
        emit OrderCreated(orderDigest);
    }

    function checkOrderFilledAndTransfer() public {
        // Check if the order has been filled on the CowSwap settlement contract
        ICowswapSettlement cowswapSettlement = ICowswapSettlement(COWSWAP_SETTLEMENT_CONTRACT);
        uint256 filledAmount = cowswapSettlement.filledAmount(storedOrderUid);

        require(filledAmount > 0, "Order not filled yet");

        // Check GNO balance of the contract
        uint256 gnoBalance = IERC20(GNO).balanceOf(address(this));
        require(gnoBalance > 0, "No GNO balance to transfer");

        // Transfer GNO to the receiver
        bool success = IERC20(GNO).transfer(RECEIVER, gnoBalance);
        require(success, "GNO transfer failed");

        // Emit event for the transfer
        emit GnoTransferred(gnoBalance, RECEIVER);
    }
}
