// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IMintableBurnable
 * @notice Interface for tokens with mint and burn capabilities
 */
interface IMintableBurnable {
    function burn(address _from, uint256 _amount) external returns (bool);
    function mint(address _to, uint256 _amount) external returns (bool);
}

/**
 * @title IERC20Burnable
 * @notice Interface for ERC20 with burnFrom capability
 */
interface IERC20Burnable {
    function burnFrom(address account, uint256 amount) external;
}

/**
 * @title NLPMinterBurner
 * @author NewLo Team
 * @notice Minter/Burner implementation for NewLoPoint token
 * @dev This contract acts as an intermediary to provide mint/burn capabilities
 *      compatible with LayerZero's MintBurnOFTAdapter
 *
 * Architecture:
 * - NewLoPoint has burn() and burnFrom() via ERC20BurnableUpgradeable
 * - NewLoPoint has mint() restricted to MINTER_ROLE
 * - This contract needs MINTER_ROLE on NewLoPoint
 * - MintBurnOFTAdapter calls this contract's burn() and mint()
 *
 * Key Features:
 * - Implements IMintableBurnable interface for LayerZero compatibility
 * - Operator management for authorized callers (only OFT Adapter)
 * - Emergency pause functionality
 * - Owner-controlled access
 *
 * Security:
 * - Only operators can call mint/burn
 * - Typically only the MintBurnOFTAdapter should be an operator
 * - Owner can add/remove operators
 */
contract NLPMinterBurner is IMintableBurnable, Ownable {
    /* ═══════════════════════════════════════════════════════════════════════
                               IMMUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice NewLoPoint token contract
    address public immutable nlpToken;

    /* ═══════════════════════════════════════════════════════════════════════
                              MUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Mapping of authorized operators (typically OFT Adapters)
    mapping(address => bool) public operators;

    /// @notice Paused state for emergency stops
    bool public paused;

    /* ═══════════════════════════════════════════════════════════════════════
                                   EVENTS
    ═══════════════════════════════════════════════════════════════════════ */

    event OperatorSet(address indexed operator, bool status);
    event Burned(address indexed from, uint256 amount, address indexed operator);
    event Minted(address indexed to, uint256 amount, address indexed operator);
    event PausedToggled(bool paused);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error NotOperator();
    error Paused();
    error ZeroAddress();
    error ZeroAmount();

    /* ═══════════════════════════════════════════════════════════════════════
                                 MODIFIERS
    ═══════════════════════════════════════════════════════════════════════ */

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Initialize the NLPMinterBurner
     * @param _nlpToken Address of NewLoPoint token
     * @param _owner Address that will own this contract (typically admin multisig)
     *
     * @dev Owner should grant MINTER_ROLE on NewLoPoint to this contract after deployment
     * @dev Owner should then set the MintBurnOFTAdapter as an operator
     */
    constructor(address _nlpToken, address _owner) Ownable(_owner) {
        if (_nlpToken == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        nlpToken = _nlpToken;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            MINT/BURN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Burn NLP tokens from an address
     * @param _from Address to burn from
     * @param _amount Amount to burn
     * @return bool Always returns true if successful
     *
     * @dev Only operators can call this
     * @dev Uses NewLoPoint's burnFrom function
     * @dev Operator (OFT Adapter) must have approval from _from
     */
    function burn(address _from, uint256 _amount) external override onlyOperator whenNotPaused returns (bool) {
        if (_from == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();

        // Call NewLoPoint's burnFrom function
        // Note: The operator (OFT Adapter) must have approval from _from
        IERC20Burnable(nlpToken).burnFrom(_from, _amount);

        emit Burned(_from, _amount, msg.sender);

        return true;
    }

    /**
     * @notice Mint NLP tokens to an address
     * @param _to Address to mint to
     * @param _amount Amount to mint
     * @return bool Always returns true if successful
     *
     * @dev Only operators can call this
     * @dev Requires this contract to have MINTER_ROLE on NewLoPoint
     */
    function mint(address _to, uint256 _amount) external override onlyOperator whenNotPaused returns (bool) {
        if (_to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();

        // Call NewLoPoint's mint function
        // Note: This contract must have MINTER_ROLE on NewLoPoint
        (bool success, bytes memory data) =
            nlpToken.call(abi.encodeWithSignature("mint(address,uint256)", _to, _amount));

        require(success && (data.length == 0 || abi.decode(data, (bool))), "Mint failed");

        emit Minted(_to, _amount, msg.sender);

        return true;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Set operator status
     * @param _operator Address of operator (typically MintBurnOFTAdapter)
     * @param _status True to authorize, false to revoke
     *
     * @dev Only owner can call
     * @dev In most cases, only the MintBurnOFTAdapter should be an operator
     */
    function setOperator(address _operator, bool _status) external onlyOwner {
        if (_operator == address(0)) revert ZeroAddress();
        operators[_operator] = _status;
        emit OperatorSet(_operator, _status);
    }

    /**
     * @notice Toggle pause state
     * @dev Only owner can call
     * @dev Pausing prevents all mint/burn operations
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedToggled(_paused);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            VIEW FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Check if an address is an authorized operator
     * @param _operator Address to check
     * @return bool True if authorized
     */
    function isOperator(address _operator) external view returns (bool) {
        return operators[_operator];
    }
}
