// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NLPOAppJPYCReceiverFinal (Official ABA Pattern Compliant Version)
 * @author NewLo Team
 * @notice Implementation based on LayerZero's official ABA pattern sample
 * @dev Inherits OAppOptionsType3 and uses combineOptions() and msg.value
 *
 * Alignment with official sample:
 * - Inherits OAppOptionsType3 ✅
 * - Uses combineOptions() ✅
 * - Extracts returnOptions from message ✅
 * - Uses msg.value to send response ✅
 *
 * Key Improvement:
 * - No pre-funding required for Receiver contract
 * - Automatically sends response using funds transferred via msg.value
 */
contract NLPOAppJPYCReceiverFinal is OApp, OAppOptionsType3, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════════════
                                   STRUCTS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Message types (same definition as Adapter)
     */
    uint16 public constant SEND_REQUEST = 1; // A→B: NLP lock request
    uint16 public constant SEND_RESPONSE = 2; // B→A: JPYC exchange result

    struct GiftMessage {
        address recipient;
        uint256 amount;
    }

    struct ResponseMessage {
        address user;
        uint256 amount;
        bool success;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                                   STATE
    ═══════════════════════════════════════════════════════════════════════ */

    IERC20 public immutable jpycToken;
    uint256 public nlpToJpycRate = 10000;
    uint256 public constant RATE_DENOMINATOR = 10000;

    /* ═══════════════════════════════════════════════════════════════════════
                                   EVENTS
    ═══════════════════════════════════════════════════════════════════════ */

    event JPYCExchanged(address indexed recipient, uint256 amount, bool success);
    event JPYCTransferred(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount);
    event JPYCTransferFailed(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount, string reason);
    event ResponseSent(address indexed user, uint256 amount, bool success, uint32 srcEid);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InvalidAmount();
    error InvalidAddress();
    error InsufficientFee();
    error InvalidMsgType();
    error InsufficientJPYCBalance(uint256 required, uint256 available);
    error TransferFailed();

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    constructor(address _jpycToken, address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {
        if (_jpycToken == address(0)) revert InvalidAddress();
        jpycToken = IERC20(_jpycToken);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ENCODING/DECODING
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Decode received message (same logic as Adapter)
     */
    function decodeMessage(bytes calldata _encodedMessage)
        public
        pure
        returns (uint16 msgType, bytes memory data, uint256 extraOptionsStart, uint256 extraOptionsLength)
    {
        (msgType, data, extraOptionsLength) = abi.decode(_encodedMessage, (uint16, bytes, uint256));
        extraOptionsStart = 256; // Same as official sample
        return (msgType, data, extraOptionsStart, extraOptionsLength);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            RECEIVE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Receive request from source chain (compliant with official sample)
     * @dev Extracts returnOptions from message and sends response using msg.value
     * @dev Follows CEI (Checks-Effects-Interactions) pattern and enhanced error handling
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        override
        nonReentrant
    {
        // Decode message (same as official sample)
        (uint16 msgType, bytes memory data, uint256 extraOptionsStart, uint256 extraOptionsLength) =
            decodeMessage(_message);

        // Only process REQUEST messages
        if (msgType != SEND_REQUEST) revert InvalidMsgType();

        // Decode gift message
        GiftMessage memory gift = abi.decode(data, (GiftMessage));

        // Calculate JPYC amount
        uint256 jpycAmount = (gift.amount * nlpToJpycRate) / RATE_DENOMINATOR;

        // Try JPYC transfer with enhanced error handling (following reference code pattern)
        bool success = _tryJPYCTransfer(gift.recipient, jpycAmount, gift.amount);

        // Extract return options from message (same as official sample)
        bytes calldata returnOptions = _message[extraOptionsStart:extraOptionsStart + extraOptionsLength];

        // Decode sender to get user address
        address user = address(uint160(uint256(_origin.sender)));

        // Send response back (using msg.value as in official sample)
        _sendResponse(_origin.srcEid, user, gift.amount, success, returnOptions);

        emit JPYCExchanged(gift.recipient, jpycAmount, success);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            INTERNAL HELPERS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Try to transfer JPYC with enhanced error handling
     * @param recipient Address to receive JPYC
     * @param jpycAmount Amount of JPYC to transfer
     * @param nlpAmount Original NLP amount (for event emission)
     * @return success Whether the transfer succeeded
     * @dev Follows reference code pattern with detailed error handling
     */
    function _tryJPYCTransfer(address recipient, uint256 jpycAmount, uint256 nlpAmount)
        internal
        returns (bool success)
    {
        success = false;
        string memory failureReason = "";

        // Check receiver has sufficient JPYC balance
        uint256 currentBalance = jpycToken.balanceOf(address(this));

        if (currentBalance < jpycAmount) {
            failureReason = "Insufficient JPYC balance";
            emit JPYCTransferFailed(recipient, jpycAmount, nlpAmount, failureReason);
            return false;
        }

        // Attempt JPYC transfer with detailed error handling (reference code pattern)
        try jpycToken.transfer(recipient, jpycAmount) returns (bool result) {
            success = result;
            if (success) {
                emit JPYCTransferred(recipient, jpycAmount, nlpAmount);
            } else {
                failureReason = "Transfer returned false";
                emit JPYCTransferFailed(recipient, jpycAmount, nlpAmount, failureReason);
            }
        } catch Error(string memory reason) {
            failureReason = reason;
            emit JPYCTransferFailed(recipient, jpycAmount, nlpAmount, reason);
        } catch {
            failureReason = "Transfer reverted";
            emit JPYCTransferFailed(recipient, jpycAmount, nlpAmount, failureReason);
        }

        return success;
    }

    /**
     * @notice Send response message using msg.value (compliant with official sample)
     * @dev msg.value contains funds transferred in A→B transaction
     * @param _srcEid Source endpoint ID to send response to
     * @param _user Original user address
     * @param _amount NLP amount
     * @param _success Whether JPYC transfer succeeded
     * @param _returnOptions Options extracted from the original message
     */
    function _sendResponse(uint32 _srcEid, address _user, uint256 _amount, bool _success, bytes calldata _returnOptions)
        internal
    {
        // Encode response data
        bytes memory responseData = abi.encode(ResponseMessage({user: _user, amount: _amount, success: _success}));

        // Encode response message (SEND_RESPONSE type, no returnOptions needed)
        bytes memory payload = abi.encode(SEND_RESPONSE, responseData);

        // Combine options (same as official sample)
        bytes memory options = combineOptions(_srcEid, SEND_RESPONSE, _returnOptions);

        // Send response using msg.value (same as official sample)
        // Important: msg.value contains funds transferred by LayerZero
        _lzSend(
            _srcEid,
            payload,
            options,
            MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), // ← Using msg.value as in official sample
            payable(address(this)) // Refund to this contract
        );

        emit ResponseSent(_user, _amount, _success, _srcEid);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Deposit JPYC into this contract
     */
    function depositJPYC(uint256 _amount) external onlyOwner {
        jpycToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Withdraw JPYC from this contract
     */
    function withdrawJPYC(address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        jpycToken.safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Update exchange rate
     */
    function setExchangeRate(uint256 _newRate) external onlyOwner {
        uint256 oldRate = nlpToJpycRate;
        nlpToJpycRate = _newRate;
        emit ExchangeRateUpdated(oldRate, _newRate);
    }

    /**
     * @notice Emergency withdraw native tokens (surplus funds only)
     */
    function withdrawNative(address payable _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        uint256 balance = address(this).balance;
        (bool success,) = _recipient.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @notice Get exchange quote
     */
    function getExchangeQuote(uint256 nlpAmount) external view returns (uint256 jpycAmount) {
        if (nlpAmount == 0) return 0;
        jpycAmount = (nlpAmount * nlpToJpycRate) / RATE_DENOMINATOR;
        return jpycAmount;
    }

    receive() external payable {}
}

/**
 * @title Key Points
 *
 * ## Full Compliance with Official ABA Pattern:
 *
 * 1. **OAppOptionsType3 Inheritance**
 *    - combineOptions() available
 *    - Options management per message type
 *
 * 2. **Extract returnOptions from Message**
 *    ```solidity
 *    bytes memory returnOptions = _message[extraOptionsStart:extraOptionsStart + extraOptionsLength];
 *    ```
 *
 * 3. **Send Response Using msg.value**
 *    ```solidity
 *    _lzSend(..., MessagingFee(msg.value, 0), ...);
 *    ```
 *    - Funds specified via addExecutorLzReceiveOption(gas, value) on Adapter side
 *    - Uses these funds to send response
 *    - No pre-funding required for Receiver contract!
 *
 * ## Fund Flow (Official Pattern):
 *
 * ```
 * User → Adapter.send{value: 1.0 ETH}
 *     ↓
 * Adapter builds options:
 *   - addExecutorLzReceiveOption(200000, 0.7 ether)
 *     ^^^^^^^                     ^^^^^^  ^^^^^^^^
 *     Receiver execution gas       Funds for B→A
 *     ↓
 * LayerZero → Receiver._lzReceive{value: 0.7 ETH}
 *     ↓
 * Receiver → _lzSend(..., MessagingFee(0.7 ETH, 0), ...)
 *     ↓
 * Response delivered to Adapter
 * ```
 *
 * ## Differences from Current Implementation:
 *
 * | Feature | Current Implementation | Final Recommended Version |
 * |---------|------------------------|---------------------------|
 * | OAppOptionsType3 | ❌ | ✅ |
 * | combineOptions() | ❌ | ✅ |
 * | returnOptions | ❌ | ✅ |
 * | msg.value usage | ❌ | ✅ |
 * | Pre-funding required | ✅ Required | ❌ Not required |
 */
