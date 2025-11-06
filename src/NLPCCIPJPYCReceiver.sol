// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IJPYCVault {
    function withdraw(address to, uint256 amount) external returns (bool);
    function balance() external view returns (uint256);
}

/**
 * @title NLPCCIPJPYCReceiver
 * @author NewLo Team
 * @notice Chainlink CCIP receiver for handling JPYC exchange requests
 * @dev Receives requests from source chain, attempts JPYC transfer, sends result back
 *
 * Key Features:
 * - Receives GiftMessage from source chain via CCIP
 * - Attempts to transfer JPYC from vault to recipient
 * - Sends ResponseMessage back to source chain with success/failure status
 * - Automatic failure recovery on source chain
 * - Provides exchange rate quotes for NLP to JPYC
 * - Supports LINK or native token for CCIP fees
 *
 * Message Flow:
 * 1. Receive GiftMessage from Chain A via CCIP
 * 2. Calculate JPYC amount based on exchange rate
 * 3. Attempt JPYC withdrawal from vault
 * 4. Send ResponseMessage back to Chain A via CCIP
 *    - success=true: Chain A burns NLP
 *    - success=false: Chain A unlocks NLP back to user
 */
contract NLPCCIPJPYCReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════════════
                                   STRUCTS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Message type identifier
     */
    enum MessageType {
        REQUEST, // Chain A -> Chain B: Request JPYC exchange
        RESPONSE // Chain B -> Chain A: Result of JPYC exchange
    }

    /**
     * @notice Request message for JPYC exchange
     * @param recipient Address to receive JPYC on destination chain
     * @param amount Amount of NLP tokens locked on source chain
     */
    struct GiftMessage {
        address recipient;
        uint256 amount;
    }

    /**
     * @notice Response message to source chain
     * @param user Original user who requested exchange
     * @param amount Amount of NLP that was locked
     * @param success Whether JPYC transfer succeeded
     */
    struct ResponseMessage {
        address user;
        uint256 amount;
        bool success;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                                   EVENTS
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Emitted when JPYC is successfully transferred
    event JPYCTransferred(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount);

    /// @notice Emitted when JPYC transfer fails
    event JPYCTransferFailed(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount);

    /// @notice Emitted when response is sent back to source chain
    event ResponseSent(address indexed user, uint256 amount, bool success, bytes32 indexed messageId);

    /// @notice Emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when vault is updated
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice Emitted when gas limit is updated
    event GasLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /// @notice Emitted when source chain configuration is updated
    event SourceChainConfigured(uint64 indexed chainSelector, address indexed adapter);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InvalidAmount();
    error InvalidAddress();
    error InsufficientVaultBalance();
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error SourceNotConfigured();

    /* ═══════════════════════════════════════════════════════════════════════
                               IMMUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice JPYC token
    IERC20 public immutable jpycToken;

    /// @notice CCIP Router
    IRouterClient public immutable ccipRouter;

    /// @notice LINK token for CCIP fees
    IERC20 public immutable linkToken;

    /* ═══════════════════════════════════════════════════════════════════════
                              MUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice JPYCVault for liquidity
    IJPYCVault public jpycVault;

    /// @notice Source chain selector (e.g., Soneium)
    uint64 public sourceChainSelector;

    /// @notice Adapter address on source chain
    address public sourceAdapter;

    /// @notice Exchange rate from NLP to JPYC (denominator: 10000)
    /// @dev 10000 = 1:1, 9000 = 0.9:1, etc.
    uint256 public nlpToJpycRate = 10000;

    /// @notice Rate denominator for precision
    uint256 public constant RATE_DENOMINATOR = 10000;

    /// @notice Gas limit for response message to source chain
    uint256 public gasLimit = 200_000;

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Initialize the NLPCCIPJPYCReceiver
     * @param _jpycToken Address of JPYC token
     * @param _jpycVault Address of JPYCVault
     * @param _ccipRouter Address of CCIP Router on destination chain
     * @param _linkToken LINK token address for fees
     * @param _owner Address that will have owner privileges
     */
    constructor(address _jpycToken, address _jpycVault, address _ccipRouter, address _linkToken, address _owner)
        CCIPReceiver(_ccipRouter)
        Ownable(_owner)
    {
        if (_jpycToken == address(0)) revert InvalidAddress();
        if (_jpycVault == address(0)) revert InvalidAddress();
        if (_ccipRouter == address(0)) revert InvalidAddress();
        if (_linkToken == address(0)) revert InvalidAddress();

        jpycToken = IERC20(_jpycToken);
        jpycVault = IJPYCVault(_jpycVault);
        ccipRouter = IRouterClient(_ccipRouter);
        linkToken = IERC20(_linkToken);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            RECEIVE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Handle incoming CCIP request messages
     * @param any2EvmMessage CCIP message
     */
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override nonReentrant {
        // Decode message type
        (MessageType msgType, bytes memory data) = abi.decode(any2EvmMessage.data, (MessageType, bytes));

        // Only process REQUEST messages
        if (msgType != MessageType.REQUEST) revert("Invalid message type");

        // Decode gift message
        GiftMessage memory gift = abi.decode(data, (GiftMessage));

        if (gift.amount == 0) revert InvalidAmount();
        if (gift.recipient == address(0)) revert InvalidAddress();

        // Calculate JPYC amount
        uint256 jpycAmount = (gift.amount * nlpToJpycRate) / RATE_DENOMINATOR;

        bool success = false;

        // Check vault has sufficient balance
        if (jpycVault.balance() >= jpycAmount) {
            // Attempt JPYC withdrawal from vault
            try jpycVault.withdraw(gift.recipient, jpycAmount) returns (bool result) {
                success = result;
                if (success) {
                    emit JPYCTransferred(gift.recipient, jpycAmount, gift.amount);
                } else {
                    emit JPYCTransferFailed(gift.recipient, jpycAmount, gift.amount);
                }
            } catch {
                emit JPYCTransferFailed(gift.recipient, jpycAmount, gift.amount);
            }
        } else {
            emit JPYCTransferFailed(gift.recipient, jpycAmount, gift.amount);
        }

        // Send response back to source chain
        _sendResponse(any2EvmMessage.sourceChainSelector, gift.recipient, gift.amount, success);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            INTERNAL FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Send response message back to source chain
     * @param _srcChainSelector Source chain selector
     * @param _user User address
     * @param _amount NLP amount
     * @param _success Whether JPYC transfer succeeded
     */
    function _sendResponse(uint64 _srcChainSelector, address _user, uint256 _amount, bool _success) internal {
        if (sourceChainSelector == 0 || sourceAdapter == address(0)) {
            revert SourceNotConfigured();
        }

        // Build response message
        bytes memory messageData = abi.encode(
            MessageType.RESPONSE, abi.encode(ResponseMessage({user: _user, amount: _amount, success: _success}))
        );

        // Build CCIP message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(sourceAdapter),
            data: messageData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            ),
            feeToken: address(linkToken)
        });

        // Get the fee required to send the message
        uint256 fees = ccipRouter.getFee(_srcChainSelector, evm2AnyMessage);

        // Check contract has enough LINK
        if (fees > linkToken.balanceOf(address(this))) {
            revert NotEnoughBalance(linkToken.balanceOf(address(this)), fees);
        }

        // Approve the Router to transfer LINK tokens
        linkToken.forceApprove(address(ccipRouter), fees);

        // Send response
        bytes32 messageId = ccipRouter.ccipSend(_srcChainSelector, evm2AnyMessage);

        emit ResponseSent(_user, _amount, _success, messageId);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            QUOTE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Get exchange quote for NLP to JPYC
     * @param nlpAmount Amount of NLP tokens
     * @return jpycAmount Estimated JPYC amount user would receive
     */
    function getExchangeQuote(uint256 nlpAmount) external view returns (uint256 jpycAmount) {
        if (nlpAmount == 0) return 0;
        jpycAmount = (nlpAmount * nlpToJpycRate) / RATE_DENOMINATOR;
        return jpycAmount;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Configure source chain
     * @param _chainSelector Source chain selector
     * @param _adapter Adapter contract address on source chain
     */
    function configureSourceChain(uint64 _chainSelector, address _adapter) external onlyOwner {
        if (_chainSelector == 0) revert InvalidAddress();
        if (_adapter == address(0)) revert InvalidAddress();

        sourceChainSelector = _chainSelector;
        sourceAdapter = _adapter;

        emit SourceChainConfigured(_chainSelector, _adapter);
    }

    /**
     * @notice Update exchange rate
     * @param _newRate New rate (denominator: 10000)
     */
    function setExchangeRate(uint256 _newRate) external onlyOwner {
        uint256 oldRate = nlpToJpycRate;
        nlpToJpycRate = _newRate;
        emit ExchangeRateUpdated(oldRate, _newRate);
    }

    /**
     * @notice Update JPYC vault
     * @param _newVault New vault address
     */
    function setJPYCVault(address _newVault) external onlyOwner {
        if (_newVault == address(0)) revert InvalidAddress();
        address oldVault = address(jpycVault);
        jpycVault = IJPYCVault(_newVault);
        emit VaultUpdated(oldVault, _newVault);
    }

    /**
     * @notice Update gas limit for response messages
     * @param _newLimit New gas limit
     */
    function setGasLimit(uint256 _newLimit) external onlyOwner {
        uint256 oldLimit = gasLimit;
        gasLimit = _newLimit;
        emit GasLimitUpdated(oldLimit, _newLimit);
    }

    /**
     * @notice Fund contract with LINK for response messages
     * @param _amount Amount of LINK to transfer
     */
    function fundForResponses(uint256 _amount) external {
        linkToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Withdraw LINK tokens
     * @param _recipient Recipient address
     * @param _amount Amount to withdraw
     */
    function withdrawLink(address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        linkToken.safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Withdraw native tokens
     * @param _recipient Recipient address
     */
    function withdrawNative(address payable _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        uint256 balance = address(this).balance;
        (bool success,) = _recipient.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @notice Emergency withdraw JPYC tokens
     * @param _recipient Recipient address
     * @param _amount Amount to withdraw
     */
    function emergencyWithdrawJPYC(address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        jpycToken.safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Allow contract to receive native tokens
     */
    receive() external payable {}
}
