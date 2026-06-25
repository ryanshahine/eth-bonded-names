// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWstETH is IERC20 {
    function getStETHByWstETH(
        uint256 wstETHAmount
    ) external view returns (uint256);
}

interface ILidoWithdrawalQueue {
    function requestWithdrawalsWstETH(
        uint256[] calldata amounts,
        address owner
    ) external returns (uint256[] memory requestIds);

    function claimWithdrawal(uint256 requestId) external;
}

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status = NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != ENTERED, "REENTRANCY");
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

contract LidoEthNameRegistry is ReentrancyGuard {
    struct NameRecord {
        address owner;
        uint256 lockedEth;
        uint256 lockedWstEth;
        uint256 registeredAt;
    }

    struct PendingWithdrawal {
        address owner;
        string name;
        uint256 lockedEth;
        uint256 requestedWstEth;
        bool claimed;
    }

    AggregatorV3Interface public immutable ethUsdFeed;
    IWstETH public immutable wstETH;
    ILidoWithdrawalQueue public immutable withdrawalQueue;

    uint256 public immutable maxOracleStaleness;

    uint256 public constant MIN_NAME_LENGTH = 1;
    uint256 public constant MAX_NAME_LENGTH = 15;

    uint256 public constant NORMAL_NAME_USD = 10;
    uint256 public constant THREE_CHAR_USD = 100;
    uint256 public constant TWO_CHAR_USD = 1_000;
    uint256 public constant ONE_CHAR_USD = 10_000;

    mapping(string => NameRecord) public records;
    mapping(address => string) public primaryName;
    mapping(uint256 => PendingWithdrawal) public pendingWithdrawals;

    event NameRegistered(
        string name,
        address indexed owner,
        uint256 lockedEth,
        uint256 lockedWstEth,
        uint256 registeredAt
    );

    event NameReleaseStarted(
        string name,
        address indexed owner,
        uint256 indexed requestId,
        uint256 requestedWstEth
    );

    event ReleasedEthClaimed(
        uint256 indexed requestId,
        address indexed owner,
        uint256 ethClaimed
    );

    event NameTransferred(
        string name,
        address indexed from,
        address indexed to
    );

    event PrimaryNameSet(address indexed owner, string name);

    error InvalidName();
    error NameUnavailable();
    error NameNotRegistered();
    error Unauthorized();
    error InsufficientPayment();
    error EthTransferFailed();
    error WstEthStakeFailed();
    error WstEthApproveFailed();
    error InvalidOracleAnswer();
    error StaleOracleAnswer();
    error InvalidAddress();
    error NoWstEthReceived();
    error WithdrawalAlreadyClaimed();
    error InvalidWithdrawalRequest();
    error DirectEthNotAccepted();

    constructor(
        address ethUsdFeedAddress,
        address wstEthAddress,
        address withdrawalQueueAddress,
        uint256 maxOracleStaleness_
    ) {
        if (ethUsdFeedAddress == address(0)) revert InvalidAddress();
        if (wstEthAddress == address(0)) revert InvalidAddress();
        if (withdrawalQueueAddress == address(0)) revert InvalidAddress();
        if (maxOracleStaleness_ == 0) revert InvalidOracleAnswer();

        ethUsdFeed = AggregatorV3Interface(ethUsdFeedAddress);
        wstETH = IWstETH(wstEthAddress);
        withdrawalQueue = ILidoWithdrawalQueue(withdrawalQueueAddress);
        maxOracleStaleness = maxOracleStaleness_;
    }

    function registerName(string calldata name) external payable nonReentrant {
        if (!_isValidName(name)) revert InvalidName();

        if (records[name].owner != address(0)) {
            revert NameUnavailable();
        }

        uint256 requiredWei = getRequiredDepositWei(name);

        if (msg.value < requiredWei) {
            revert InsufficientPayment();
        }

        uint256 wstEthBefore = wstETH.balanceOf(address(this));

        (bool success, ) = address(wstETH).call{value: requiredWei}("");
        if (!success) revert WstEthStakeFailed();

        uint256 wstEthAfter = wstETH.balanceOf(address(this));
        uint256 receivedWstEth = wstEthAfter - wstEthBefore;

        if (receivedWstEth == 0) revert NoWstEthReceived();

        records[name] = NameRecord({
            owner: msg.sender,
            lockedEth: requiredWei,
            lockedWstEth: receivedWstEth,
            registeredAt: block.timestamp
        });

        uint256 refund = msg.value - requiredWei;

        if (refund > 0) {
            _safeTransferETH(msg.sender, refund);
        }

        emit NameRegistered(
            name,
            msg.sender,
            requiredWei,
            receivedWstEth,
            block.timestamp
        );
    }

    function releaseName(
        string calldata name
    ) external nonReentrant returns (uint256 requestId) {
        if (!_isValidName(name)) revert InvalidName();

        NameRecord memory record = records[name];

        if (record.owner == address(0)) {
            revert NameNotRegistered();
        }

        if (record.owner != msg.sender) {
            revert Unauthorized();
        }

        delete records[name];

        if (_sameString(primaryName[msg.sender], name)) {
            delete primaryName[msg.sender];
        }

        bool approveSuccess = wstETH.approve(
            address(withdrawalQueue),
            record.lockedWstEth
        );

        if (!approveSuccess) revert WstEthApproveFailed();

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = record.lockedWstEth;

        uint256[] memory requestIds = withdrawalQueue.requestWithdrawalsWstETH(
            amounts,
            address(this)
        );

        if (requestIds.length != 1) revert InvalidWithdrawalRequest();

        requestId = requestIds[0];

        pendingWithdrawals[requestId] = PendingWithdrawal({
            owner: msg.sender,
            name: name,
            lockedEth: record.lockedEth,
            requestedWstEth: record.lockedWstEth,
            claimed: false
        });

        emit NameReleaseStarted(
            name,
            msg.sender,
            requestId,
            record.lockedWstEth
        );
    }

    function claimReleasedEth(uint256 requestId) external nonReentrant {
        PendingWithdrawal storage withdrawal = pendingWithdrawals[requestId];

        if (withdrawal.owner == address(0)) {
            revert InvalidWithdrawalRequest();
        }

        if (withdrawal.owner != msg.sender) {
            revert Unauthorized();
        }

        if (withdrawal.claimed) {
            revert WithdrawalAlreadyClaimed();
        }

        withdrawal.claimed = true;

        uint256 ethBefore = address(this).balance;

        withdrawalQueue.claimWithdrawal(requestId);

        uint256 ethAfter = address(this).balance;
        uint256 ethReceived = ethAfter - ethBefore;

        _safeTransferETH(msg.sender, ethReceived);

        emit ReleasedEthClaimed(requestId, msg.sender, ethReceived);
    }

    function transferName(string calldata name, address to) external {
        if (!_isValidName(name)) revert InvalidName();
        if (to == address(0)) revert InvalidAddress();

        NameRecord storage record = records[name];

        if (record.owner == address(0)) {
            revert NameNotRegistered();
        }

        if (record.owner != msg.sender) {
            revert Unauthorized();
        }

        address from = msg.sender;

        record.owner = to;

        if (_sameString(primaryName[from], name)) {
            delete primaryName[from];
        }

        emit NameTransferred(name, from, to);
    }

    function setPrimaryName(string calldata name) external {
        if (!_isValidName(name)) revert InvalidName();

        NameRecord memory record = records[name];

        if (record.owner == address(0)) {
            revert NameNotRegistered();
        }

        if (record.owner != msg.sender) {
            revert Unauthorized();
        }

        primaryName[msg.sender] = name;

        emit PrimaryNameSet(msg.sender, name);
    }

    function clearPrimaryName() external {
        delete primaryName[msg.sender];

        emit PrimaryNameSet(msg.sender, "");
    }

    function ownerOf(string calldata name) external view returns (address) {
        return records[name].owner;
    }

    function isAvailable(string calldata name) external view returns (bool) {
        if (!_isValidName(name)) return false;

        return records[name].owner == address(0);
    }

    function isValidName(string calldata name) external pure returns (bool) {
        return _isValidName(name);
    }

    function getUsdDepositForName(
        string calldata name
    ) public pure returns (uint256) {
        uint256 length = bytes(name).length;

        if (length == 1) return ONE_CHAR_USD;
        if (length == 2) return TWO_CHAR_USD;
        if (length == 3) return THREE_CHAR_USD;

        return NORMAL_NAME_USD;
    }

    function getRequiredDepositWei(
        string calldata name
    ) public view returns (uint256) {
        if (!_isValidName(name)) revert InvalidName();

        uint256 usdAmount = getUsdDepositForName(name);
        uint256 ethUsdPrice = _getEthUsdPrice();
        uint8 feedDecimals = ethUsdFeed.decimals();

        return (usdAmount * (10 ** feedDecimals) * 1 ether) / ethUsdPrice;
    }

    function getCurrentStEthValue(
        string calldata name
    ) external view returns (uint256) {
        NameRecord memory record = records[name];

        if (record.owner == address(0)) {
            return 0;
        }

        return wstETH.getStETHByWstETH(record.lockedWstEth);
    }

    function getCurrentYieldEstimate(
        string calldata name
    ) external view returns (int256) {
        NameRecord memory record = records[name];

        if (record.owner == address(0)) {
            return 0;
        }

        uint256 currentStEthValue = wstETH.getStETHByWstETH(
            record.lockedWstEth
        );

        return int256(currentStEthValue) - int256(record.lockedEth);
    }

    function _getEthUsdPrice() internal view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ethUsdFeed.latestRoundData();

        if (answer <= 0) revert InvalidOracleAnswer();
        if (updatedAt == 0) revert InvalidOracleAnswer();
        if (answeredInRound < roundId) revert InvalidOracleAnswer();

        if (block.timestamp - updatedAt > maxOracleStaleness) {
            revert StaleOracleAnswer();
        }

        return uint256(answer);
    }

    function _isValidName(string memory name) internal pure returns (bool) {
        bytes memory b = bytes(name);

        if (b.length < MIN_NAME_LENGTH) return false;
        if (b.length > MAX_NAME_LENGTH) return false;

        if (b[0] == 0x2d) return false;
        if (b[b.length - 1] == 0x2d) return false;

        for (uint256 i = 0; i < b.length; i++) {
            bytes1 char = b[i];

            bool isNumber = char >= 0x30 && char <= 0x39;
            bool isLowercaseLetter = char >= 0x61 && char <= 0x7a;
            bool isHyphen = char == 0x2d;

            if (!isNumber && !isLowercaseLetter && !isHyphen) {
                return false;
            }

            if (isHyphen && i + 1 < b.length && b[i + 1] == 0x2d) {
                return false;
            }
        }

        return true;
    }

    function _sameString(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = payable(to).call{value: amount}("");

        if (!success) revert EthTransferFailed();
    }

    receive() external payable {
        if (msg.sender != address(withdrawalQueue)) {
            revert DirectEthNotAccepted();
        }
    }
}
