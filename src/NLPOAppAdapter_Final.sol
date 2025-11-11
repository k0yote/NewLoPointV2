// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INLPMinterBurner {
    function burn(address from, uint256 amount) external;
}

/**
 * @title NLPOAppAdapter (Official ABA Pattern Compliant Version)
 * @author NewLo Team
 * @notice Implementation based on LayerZero's official ABA pattern sample
 * @dev Inherits OAppOptionsType3 and uses combineOptions()
 *
 * Alignment with official sample:
 * - Inherits OAppOptionsType3 ✅
 * - Uses combineOptions() ✅
 * - Encodes returnOptions in message ✅
 * - Uses msg.value to send response ✅
 *
 * Official sample: https://docs.layerzero.network/v2/developers/evm/oapp/overview
 */
contract NLPOAppAdapterFinal is OApp, OAppOptionsType3, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════════════
                                   STRUCTS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Message types (same as official sample)
     * @dev These values are used in combineOptions()
     */
    uint16 public constant SEND_REQUEST = 1; // A→B: NLP lock request
    uint16 public constant SEND_RESPONSE = 2; // B→A: JPYC exchange result

    /**
     * @notice Request message for JPYC exchange
     * @param recipient Address to receive JPYC on destination chain
     * @param amount Amount of NLP tokens locked
     */
    struct GiftMessage {
        address recipient;
        uint256 amount;
    }

    /**
     * @notice Response message from destination chain
     * @param user Original user who requested exchange
     * @param amount Amount of NLP that was locked
     * @param success Whether JPYC transfer succeeded
     */
    struct ResponseMessage {
        address user;
        uint256 amount;
        bool success;
    }

    /**
     * @notice Supported token types for exchange
     */
    enum TokenType {
        JPYC
    }

    /* ═══════════════════════════════════════════════════════════════════════
                                   STATE
    ═══════════════════════════════════════════════════════════════════════ */

    IERC20Permit public immutable nlpToken;
    INLPMinterBurner public immutable minterBurner;

    mapping(address => uint256) public lockedBalances;
    uint256 public nlpToJpycRate = 10000;
    uint256 public constant RATE_DENOMINATOR = 10000;

    /// @notice Exchange fee in basis points (100 = 1%)
    uint256 public exchangeFee = 0;

    /// @notice Operational fee in basis points (100 = 1%)
    uint256 public operationalFee = 0;

    /// @notice Maximum allowed fee (5%)
    uint256 public constant MAX_FEE = 500;

    /* ═══════════════════════════════════════════════════════════════════════
                                   EVENTS
    ═══════════════════════════════════════════════════════════════════════ */

    event NLPLocked(address indexed user, uint256 amount, uint32 dstEid);
    event NLPBurned(address indexed user, uint256 amount);
    event NLPUnlocked(address indexed user, uint256 amount);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
    event ExchangeFeeUpdated(uint256 oldFee, uint256 newFee);
    event OperationalFeeUpdated(uint256 oldFee, uint256 newFee);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InvalidAmount();
    error InvalidAddress();
    error InsufficientFee();
    error NoLockedTokens();
    error PermitFailed();
    error InvalidMsgType();
    error InvalidFeeRate(uint256 fee, uint256 maxFee);
    error BurnFailed(address user, uint256 amount);
    error TransferFailed();

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    constructor(address _nlpToken, address _minterBurner, address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        Ownable(_owner)
    {
        if (_nlpToken == address(0)) revert InvalidAddress();
        if (_minterBurner == address(0)) revert InvalidAddress();

        nlpToken = IERC20Permit(_nlpToken);
        minterBurner = INLPMinterBurner(_minterBurner);

        IERC20(_nlpToken).forceApprove(_minterBurner, type(uint256).max);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ENCODING/DECODING
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Encode message with return options (same as official sample)
     * @dev Encodes message type, data, and returnOptions
     * @param _msgType Message type (SEND_REQUEST or SEND_RESPONSE)
     * @param _data Encoded message data (GiftMessage or ResponseMessage)
     * @param _extraReturnOptions Options for B→A return message
     */
    function encodeMessage(uint16 _msgType, bytes memory _data, bytes memory _extraReturnOptions)
        public
        pure
        returns (bytes memory)
    {
        uint256 extraOptionsLength = _extraReturnOptions.length;
        // Same format as official sample: includes length information at both ends
        return abi.encode(_msgType, _data, extraOptionsLength, _extraReturnOptions, extraOptionsLength);
    }

    /**
     * @notice Decode received message
     * @param _encodedMessage Encoded message
     * @return msgType Message type
     * @return data Message data
     * @return extraOptionsStart Start position of extra options
     * @return extraOptionsLength Length of extra options
     */
    function decodeMessage(bytes calldata _encodedMessage)
        public
        pure
        returns (uint16 msgType, bytes memory data, uint256 extraOptionsStart, uint256 extraOptionsLength)
    {
        // Decode message type and data
        (msgType, data, extraOptionsLength) = abi.decode(_encodedMessage, (uint16, bytes, uint256));

        // Calculate starting position of extraOptions
        // uint16 (2 bytes) + dynamic bytes + uint256 (32 bytes) = variable
        // For simplicity, use fixed offset as in official sample
        extraOptionsStart = 256; // May need adjustment

        return (msgType, data, extraOptionsStart, extraOptionsLength);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            SEND FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Send NLP cross-chain with ABA pattern (compliant with official sample)
     * @param _dstEid Destination endpoint ID
     * @param _recipient Recipient address on destination chain
     * @param _amount Amount of NLP to send
     * @param _extraSendOptions Additional options for A→B (gas settings)
     * @param _extraReturnOptions Additional options for B→A (gas settings)
     */
    function send(
        uint32 _dstEid,
        address _recipient,
        uint256 _amount,
        bytes calldata _extraSendOptions, // A→B gas settings
        bytes calldata _extraReturnOptions // B→A gas settings
    ) external payable nonReentrant returns (MessagingReceipt memory receipt) {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();

        // Lock NLP tokens
        IERC20(address(nlpToken)).safeTransferFrom(msg.sender, address(this), _amount);
        lockedBalances[msg.sender] += _amount;

        // Encode gift data
        bytes memory giftData = abi.encode(GiftMessage({recipient: _recipient, amount: _amount}));

        // Encode full message with return options (same as official sample)
        bytes memory payload = encodeMessage(SEND_REQUEST, giftData, _extraReturnOptions);

        // Combine options (same as official sample)
        bytes memory options = combineOptions(_dstEid, SEND_REQUEST, _extraSendOptions);

        // Send message
        receipt = _lzSend(_dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit NLPLocked(msg.sender, _amount, _dstEid);
        return receipt;
    }

    /**
     * @notice Send with Permit (gasless approval)
     * @param _dstEid Destination endpoint ID
     * @param _recipient Recipient address
     * @param _amount Amount to send
     * @param _extraSendOptions Options for A→B
     * @param _extraReturnOptions Options for B→A
     * @param _deadline Permit deadline
     * @param _v Signature v
     * @param _r Signature r
     * @param _s Signature s
     */
    function sendWithPermit(
        uint32 _dstEid,
        address _recipient,
        uint256 _amount,
        bytes calldata _extraSendOptions,
        bytes calldata _extraReturnOptions,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external payable nonReentrant returns (MessagingReceipt memory receipt) {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();
        if (block.timestamp > _deadline) revert PermitFailed();

        // Execute permit
        try nlpToken.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {}
        catch {
            revert PermitFailed();
        }

        // Lock NLP tokens
        IERC20(address(nlpToken)).safeTransferFrom(msg.sender, address(this), _amount);
        lockedBalances[msg.sender] += _amount;

        // Encode message
        bytes memory giftData = abi.encode(GiftMessage({recipient: _recipient, amount: _amount}));
        bytes memory payload = encodeMessage(SEND_REQUEST, giftData, _extraReturnOptions);
        bytes memory options = combineOptions(_dstEid, SEND_REQUEST, _extraSendOptions);

        // Send message
        receipt = _lzSend(_dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit NLPLocked(msg.sender, _amount, _dstEid);
        return receipt;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            RECEIVE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Receive response message from destination chain
     * @dev Processes RESPONSE messages and burns or unlocks NLP
     * @dev Follows CEI (Checks-Effects-Interactions) pattern for security
     */
    function _lzReceive(
        Origin calldata,
        /*_origin*/
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
        // Decode message
        (uint16 msgType, bytes memory data,,) = decodeMessage(_message);

        // Only process RESPONSE messages
        if (msgType != SEND_RESPONSE) revert InvalidMsgType();

        // Decode response
        ResponseMessage memory response = abi.decode(data, (ResponseMessage));

        // ============================================
        // CHECKS: Validate response data
        // ============================================
        if (response.amount == 0) revert InvalidAmount();
        if (response.user == address(0)) revert InvalidAddress();
        if (lockedBalances[response.user] < response.amount) revert NoLockedTokens();

        // ============================================
        // EFFECTS: Update state before interactions
        // ============================================
        // Reduce locked balance (CEI pattern)
        lockedBalances[response.user] -= response.amount;

        // ============================================
        // INTERACTIONS: External calls
        // ============================================
        if (response.success) {
            // JPYC transfer succeeded -> Burn NLP
            _burnNLP(response.user, response.amount);
        } else {
            // JPYC transfer failed -> Unlock NLP back to user
            _unlockNLP(response.user, response.amount);
        }
    }

    /**
     * @notice Burn NLP tokens (internal helper following reference code pattern)
     * @param user User address for event emission
     * @param amount Amount of NLP to burn from this contract
     * @dev Uses try-catch pattern from reference code for robust error handling
     */
    function _burnNLP(address user, uint256 amount) internal {
        try minterBurner.burn(address(this), amount) {
            // Burn successful
            emit NLPBurned(user, amount);
        } catch {
            // Burn failed - this should never happen in normal operation
            revert BurnFailed(user, amount);
        }
    }

    /**
     * @notice Unlock NLP tokens back to user (internal helper)
     * @param user User address to receive unlocked tokens
     * @param amount Amount of NLP to unlock
     * @dev Uses SafeERC20 for secure transfer
     */
    function _unlockNLP(address user, uint256 amount) internal {
        // SafeERC20.safeTransfer already handles revert on failure
        IERC20(address(nlpToken)).safeTransfer(user, amount);
        emit NLPUnlocked(user, amount);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            QUOTE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Quote the fee for sending (same as official sample)
     * @param _dstEid Destination endpoint ID
     * @param _recipient Recipient address
     * @param _amount Amount to send
     * @param _extraSendOptions Options for A→B
     * @param _extraReturnOptions Options for B→A
     * @param _payInLzToken Whether to pay in LZ token
     * @return fee Estimated messaging fee
     */
    function quoteSend(
        uint32 _dstEid,
        address _recipient,
        uint256 _amount,
        bytes calldata _extraSendOptions,
        bytes calldata _extraReturnOptions,
        bool _payInLzToken
    ) external view returns (MessagingFee memory fee) {
        bytes memory giftData = abi.encode(GiftMessage({recipient: _recipient, amount: _amount}));
        bytes memory payload = encodeMessage(SEND_REQUEST, giftData, _extraReturnOptions);
        bytes memory options = combineOptions(_dstEid, SEND_REQUEST, _extraSendOptions);
        fee = _quote(_dstEid, payload, options, _payInLzToken);
    }

    /**
     * @notice Get exchange quote for NLP to JPYC with fees
     * @dev tokenType parameter is reserved for future use (currently only JPYC supported)
     * @param nlpAmount Amount of NLP tokens
     * @return grossAmount Gross JPYC amount before fees
     * @return exchangeFeeAmount Exchange fee in JPYC
     * @return operationalFeeAmount Operational fee in JPYC
     * @return netAmount Net JPYC amount after fees
     */
    function getExchangeQuote(
        TokenType,
        /*tokenType*/
        uint256 nlpAmount
    )
        external
        view
        returns (uint256 grossAmount, uint256 exchangeFeeAmount, uint256 operationalFeeAmount, uint256 netAmount)
    {
        if (nlpAmount == 0) return (0, 0, 0, 0);

        // Calculate gross JPYC amount
        grossAmount = (nlpAmount * nlpToJpycRate) / RATE_DENOMINATOR;

        // Calculate fees in JPYC
        exchangeFeeAmount = (grossAmount * exchangeFee) / 10000;
        operationalFeeAmount = (grossAmount * operationalFee) / 10000;

        // Calculate net amount after fees
        netAmount = grossAmount - exchangeFeeAmount - operationalFeeAmount;

        return (grossAmount, exchangeFeeAmount, operationalFeeAmount, netAmount);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    function setExchangeRate(uint256 _newRate) external onlyOwner {
        uint256 oldRate = nlpToJpycRate;
        nlpToJpycRate = _newRate;
        emit ExchangeRateUpdated(oldRate, _newRate);
    }

    /**
     * @notice Set exchange fee rate
     * @param _newFee New exchange fee in basis points (100 = 1%)
     */
    function setExchangeFee(uint256 _newFee) external onlyOwner {
        if (_newFee > MAX_FEE) revert InvalidFeeRate(_newFee, MAX_FEE);
        uint256 oldFee = exchangeFee;
        exchangeFee = _newFee;
        emit ExchangeFeeUpdated(oldFee, _newFee);
    }

    /**
     * @notice Set operational fee rate
     * @param _newFee New operational fee in basis points (100 = 1%)
     */
    function setOperationalFee(uint256 _newFee) external onlyOwner {
        if (_newFee > MAX_FEE) revert InvalidFeeRate(_newFee, MAX_FEE);
        uint256 oldFee = operationalFee;
        operationalFee = _newFee;
        emit OperationalFeeUpdated(oldFee, _newFee);
    }

    function withdrawNative(address payable _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        uint256 balance = address(this).balance;
        (bool success,) = _recipient.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    receive() external payable {}
}

/**
 * @title Usage Example
 *
 * // 1. Quote full cost (A→B + B→A)
 * bytes memory sendOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0.1 ether);
 * bytes memory returnOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(100000, 0);
 *
 * MessagingFee memory fee = adapter.quoteSend(
 *     polygonEid,
 *     recipient,
 *     amount,
 *     sendOptions,      // A→B options (includes gas + value for B→A)
 *     returnOptions,    // B→A options
 *     false
 * );
 *
 * // 2. Send transaction
 * adapter.send{value: fee.nativeFee}(
 *     polygonEid,
 *     recipient,
 *     amount,
 *     sendOptions,
 *     returnOptions
 * );
 */
