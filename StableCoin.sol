// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title StableCoin - A Collateral-Backed DAI-like Stablecoin
 * @dev This contract implements a decentralized stablecoin backed by multiple collateral types
 * with risk parameters, liquidation mechanisms, and governance features.
 */
contract StableCoin is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    // Collateral information
    struct CollateralType {
        address tokenAddress;
        address priceFeed;
        uint256 collateralRatio; // Percentage (e.g., 150% = 15000)
        uint256 debtCeiling; // Maximum debt allowed for this collateral
        uint256 totalDeposited; // Total amount deposited
        bool enabled;
    }

    // User collateral positions
    struct Position {
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    // Constants
    uint256 public constant PRICE_FEED_PRECISION = 1e8;
    uint256 public constant RATIO_PRECISION = 1e4;
    uint256 public constant LIQUIDATION_PENALTY = 11000; // 10%
    uint256 public constant LIQUIDATION_RATIO = 11000; // 110%
    uint256 public constant MIN_COLLATERAL_RATIO = 12500; // 125%
    uint256 public constant PROTOCOL_FEE = 50; // 0.5%
    uint256 public constant FEE_PRECISION = 10000;

    // State variables
    mapping(address => CollateralType) public collateralTypes;
    mapping(address => mapping(address => Position)) public positions;
    address[] public enabledCollaterals;
    address public feeReceiver;
    uint256 public totalDebt;
    uint256 public globalDebtCeiling;

    // Events
    event CollateralAdded(address indexed token, address priceFeed, uint256 ratio, uint256 ceiling);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event StablecoinMinted(address indexed user, uint256 amount);
    event StablecoinBurned(address indexed user, uint256 amount);
    event PositionLiquidated(address indexed user, address indexed liquidator, address indexed collateral, uint256 debtCovered, uint256 collateralSeized);
    event ParametersUpdated(uint256 newGlobalDebtCeiling);
    event FeeReceiverUpdated(address newFeeReceiver);

    /**
     * @dev Initializes the stablecoin with basic parameters
     * @param _name Name of the stablecoin
     * @param _symbol Symbol of the stablecoin
     * @param _feeReceiver Address to receive protocol fees
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _feeReceiver
    ) ERC20(_name, _symbol) {
        require(_feeReceiver != address(0), "Invalid fee receiver");
        feeReceiver = _feeReceiver;
        globalDebtCeiling = 10_000_000 * 10 ** decimals(); // Initial global debt ceiling
    }

    /**
     * @dev Adds a new collateral type to the system
     * @param _token Address of the collateral token
     * @param _priceFeed Chainlink price feed for the collateral
     * @param _ratio Collateral ratio (e.g., 150% = 15000)
     * @param _ceiling Debt ceiling for this collateral type
     */
    function addCollateralType(
        address _token,
        address _priceFeed,
        uint256 _ratio,
        uint256 _ceiling
    ) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(_priceFeed != address(0), "Invalid price feed");
        require(_ratio >= MIN_COLLATERAL_RATIO, "Ratio too low");
        require(!collateralTypes[_token].enabled, "Collateral already added");

        collateralTypes[_token] = CollateralType({
            tokenAddress: _token,
            priceFeed: _priceFeed,
            collateralRatio: _ratio,
            debtCeiling: _ceiling,
            totalDeposited: 0,
            enabled: true
        });

        enabledCollaterals.push(_token);
        emit CollateralAdded(_token, _priceFeed, _ratio, _ceiling);
    }

    /**
     * @dev Deposits collateral and mints stablecoins
     * @param _token Collateral token address
     * @param _amount Amount of collateral to deposit
     * @param _mintAmount Amount of stablecoins to mint
     */
    function depositAndMint(
        address _token,
        uint256 _amount,
        uint256 _mintAmount
    ) external nonReentrant {
        require(collateralTypes[_token].enabled, "Collateral not enabled");
        require(_amount > 0, "Amount must be greater than 0");

        // Transfer collateral from user
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);

        // Update position
        Position storage position = positions[msg.sender][_token];
        position.collateralAmount += _amount;
        collateralTypes[_token].totalDeposited += _amount;

        if (_mintAmount > 0) {
            _mintStablecoin(_token, _mintAmount);
        }

        emit CollateralDeposited(msg.sender, _token, _amount);
    }

    /**
     * @dev Mints stablecoins against existing collateral
     * @param _token Collateral token address
     * @param _amount Amount of stablecoins to mint
     */
    function mint(address _token, uint256 _amount) external nonReentrant {
        require(collateralTypes[_token].enabled, "Collateral not enabled");
        require(_amount > 0, "Amount must be greater than 0");
        _mintStablecoin(_token, _amount);
    }

    /**
     * @dev Internal function to mint stablecoins with collateral checks
     */
    function _mintStablecoin(address _token, uint256 _amount) internal {
        Position storage position = positions[msg.sender][_token];
        CollateralType memory collateral = collateralTypes[_token];

        // Check collateral ratio
        uint256 collateralValue = getCollateralValue(msg.sender, _token);
        uint256 newDebt = position.debtAmount + _amount;
        require(
            collateralValue >= (newDebt * collateral.collateralRatio) / RATIO_PRECISION,
            "Insufficient collateral"
        );

        // Check debt ceilings
        require(
            collateral.totalDeposited <= collateral.debtCeiling,
            "Collateral debt ceiling reached"
        );
        require(totalDebt + _amount <= globalDebtCeiling, "Global debt ceiling reached");

        // Update state
        position.debtAmount = newDebt;
        totalDebt += _amount;

        // Mint stablecoins
        _mint(msg.sender, _amount);
        emit StablecoinMinted(msg.sender, _amount);
    }

    /**
     * @dev Burns stablecoins and withdraws collateral
     * @param _token Collateral token address
     * @param _burnAmount Amount of stablecoins to burn
     * @param _withdrawAmount Amount of collateral to withdraw
     */
    function burnAndWithdraw(
        address _token,
        uint256 _burnAmount,
        uint256 _withdrawAmount
    ) external nonReentrant {
        require(collateralTypes[_token].enabled, "Collateral not enabled");
        Position storage position = positions[msg.sender][_token];

        if (_burnAmount > 0) {
            _burnStablecoin(_token, _burnAmount);
        }

        if (_withdrawAmount > 0) {
            require(
                _withdrawAmount <= position.collateralAmount,
                "Insufficient collateral"
            );

            // Check collateral ratio after withdrawal
            uint256 remainingCollateral = position.collateralAmount - _withdrawAmount;
            uint256 collateralValue = (remainingCollateral * getCollateralPrice(_token)) /
                (10 ** IERC20Metadata(_token).decimals());
            require(
                collateralValue >= (position.debtAmount * collateralTypes[_token].collateralRatio) / RATIO_PRECISION,
                "Insufficient collateral after withdrawal"
            );

            // Update state
            position.collateralAmount = remainingCollateral;
            collateralTypes[_token].totalDeposited -= _withdrawAmount;

            // Transfer collateral to user
            IERC20(_token).transfer(msg.sender, _withdrawAmount);
            emit CollateralWithdrawn(msg.sender, _token, _withdrawAmount);
        }
    }

    /**
     * @dev Internal function to burn stablecoins
     */
    function _burnStablecoin(address _token, uint256 _amount) internal {
        Position storage position = positions[msg.sender][_token];
        require(_amount <= position.debtAmount, "Debt amount exceeded");

        // Burn stablecoins
        burn(_amount);

        // Update state
        position.debtAmount -= _amount;
        totalDebt -= _amount;
        emit StablecoinBurned(msg.sender, _amount);
    }

    /**
     * @dev Liquidates an undercollateralized position
     * @param _user Address of the user with undercollateralized position
     * @param _token Collateral token address
     * @param _debtAmount Amount of debt to cover
     */
    function liquidate(
        address _user,
        address _token,
        uint256 _debtAmount
    ) external nonReentrant {
        require(collateralTypes[_token].enabled, "Collateral not enabled");
        Position storage position = positions[_user][_token];

        // Check if position is undercollateralized
        uint256 collateralValue = getCollateralValue(_user, _token);
        require(
            collateralValue < (position.debtAmount * LIQUIDATION_RATIO) / RATIO_PRECISION,
            "Position not liquidatable"
        );

        require(_debtAmount > 0, "Amount must be greater than 0");
        require(_debtAmount <= position.debtAmount, "Debt amount exceeded");

        // Calculate collateral to seize (with penalty)
        uint256 collateralPrice = getCollateralPrice(_token);
        uint256 collateralToSeize = (_debtAmount *
            LIQUIDATION_PENALTY *
            (10 ** IERC20Metadata(_token).decimals())) / (collateralPrice * RATIO_PRECISION);

        require(
            collateralToSeize <= position.collateralAmount,
            "Insufficient collateral to seize"
        );

        // Transfer stablecoins from liquidator
        transferFrom(msg.sender, address(this), _debtAmount);
        burn(_debtAmount);

        // Update position
        position.debtAmount -= _debtAmount;
        position.collateralAmount -= collateralToSeize;
        totalDebt -= _debtAmount;
        collateralTypes[_token].totalDeposited -= collateralToSeize;

        // Transfer collateral to liquidator (minus protocol fee)
        uint256 protocolFee = (collateralToSeize * PROTOCOL_FEE) / FEE_PRECISION;
        uint256 liquidatorAmount = collateralToSeize - protocolFee;

        IERC20(_token).transfer(msg.sender, liquidatorAmount);
        if (protocolFee > 0) {
            IERC20(_token).transfer(feeReceiver, protocolFee);
        }

        emit PositionLiquidated(_user, msg.sender, _token, _debtAmount, collateralToSeize);
    }

    /**
     * @dev Updates global debt ceiling
     * @param _newCeiling New global debt ceiling
     */
    function updateGlobalDebtCeiling(uint256 _newCeiling) external onlyOwner {
        require(_newCeiling > totalDebt, "Ceiling below current debt");
        globalDebtCeiling = _newCeiling;
        emit ParametersUpdated(_newCeiling);
    }

    /**
     * @dev Updates fee receiver address
     * @param _newFeeReceiver New fee receiver address
     */
    function updateFeeReceiver(address _newFeeReceiver) external onlyOwner {
        require(_newFeeReceiver != address(0), "Invalid address");
        feeReceiver = _newFeeReceiver;
        emit FeeReceiverUpdated(_newFeeReceiver);
    }

    /**
     * @dev Gets the current price of a collateral token
     * @param _token Collateral token address
     * @return price Current price of the collateral
     */
    function getCollateralPrice(address _token) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(collateralTypes[_token].priceFeed);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    /**
     * @dev Gets the collateral value for a user's position
     * @param _user User address
     * @param _token Collateral token address
     * @return value Total collateral value in stablecoin terms
     */
    function getCollateralValue(address _user, address _token) public view returns (uint256) {
        Position memory position = positions[_user][_token];
        uint256 price = getCollateralPrice(_token);
        return (position.collateralAmount * price) / (10 ** IERC20Metadata(_token).decimals());
    }

    /**
     * @dev Gets the collateralization ratio for a user's position
     * @param _user User address
     * @param _token Collateral token address
     * @return ratio Collateralization ratio (e.g., 150% = 15000)
     */
    function getCollateralizationRatio(address _user, address _token) external view returns (uint256) {
        Position memory position = positions[_user][_token];
        if (position.debtAmount == 0) return type(uint256).max;
        uint256 collateralValue = getCollateralValue(_user, _token);
        return (collateralValue * RATIO_PRECISION) / position.debtAmount;
    }

    /**
     * @dev Gets the list of enabled collateral tokens
     * @return Array of enabled collateral token addresses
     */
    function getEnabledCollaterals() external view returns (address[] memory) {
        return enabledCollaterals;
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
