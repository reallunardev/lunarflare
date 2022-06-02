// contracts/Incinerator.sol
// SPDX-License-Identifier: MIT

/*

██╗░░░░░██╗░░░██╗███╗░░██╗░█████╗░██████╗░  ███████╗██╗░░░░░░█████╗░██████╗░███████╗
██║░░░░░██║░░░██║████╗░██║██╔══██╗██╔══██╗  ██╔════╝██║░░░░░██╔══██╗██╔══██╗██╔════╝
██║░░░░░██║░░░██║██╔██╗██║███████║██████╔╝  █████╗░░██║░░░░░███████║██████╔╝█████╗░░
██║░░░░░██║░░░██║██║╚████║██╔══██║██╔══██╗  ██╔══╝░░██║░░░░░██╔══██║██╔══██╗██╔══╝░░
███████╗╚██████╔╝██║░╚███║██║░░██║██║░░██║  ██║░░░░░███████╗██║░░██║██║░░██║███████╗
╚══════╝░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░╚═╝  ╚═╝░░░░░╚══════╝╚═╝░░╚═╝╚═╝░░╚═╝╚══════╝


█▄▄ █░█ █▀█ █▄░█   █ ▀█▀   █▀▄ █▀█ █░█░█ █▄░█
█▄█ █▄█ █▀▄ █░▀█   █ ░█░   █▄▀ █▄█ ▀▄▀▄▀ █░▀█

developed by reallunardev.eth
*/

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./DateTimeLib.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;

    function makeOrphanAndStripOfAssets(
        address newOwner,
        address directionForRecovery
    ) external;
}

interface IIncinerator is IERC20 {
    function _DECIMALFACTOR() external view returns (uint256);

    function restoreAllFees() external;

    function removeAllFees() external;
}

interface IIgniter is IERC20 {
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to
    ) external;

    function lp_EtherPerLPToken(
        address pairedToken,
        address sourceContract,
        address checkpair
    ) external view returns (uint256);

    function lp_TotalTokensInLPOwnedByProject(
        address sourceContract,
        address checkpair
    ) external view returns (uint256);

    function lp_TotalTokens(address checkpair) external view returns (uint256);

    function makeOrphanAndStripOfAssets(
        address newOwner,
        bool moveFunds,
        address directionForRecovery
    ) external;
}

contract Incinerator is
    Context, //Because you need it.
    IERC20Metadata, //Cause they didn't do it in the first one!
    ReentrancyGuard, //To prevent funky stuff ;)
    Ownable //Fpr the Ownage C[o] Keep away!
{
    using Counters for Counters.Counter;

    Counters.Counter private _dayCounter;

    struct DAILY_BURN {
        uint256 id;
        uint256 tokenStartDay;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 amountTobeBurned;
        uint256 amountBurned;
    }

    struct KEY_ADDRESSES {
        address routerAddress;
        address payload2Wallet;
        address payload1Wallet;
        address igniterContract;
    }

    struct FEES {
        uint256 burnSwapRedirect;
        uint256 baseTransferFee;
        uint256 buyBurnFee;
        uint256 sellBurnFee;
        uint256 transferFee;
        uint256 buyLPBurn;
        uint256 sellBurnLP;
        uint256 transferLPBurn;
        uint256 sF1;
        uint256 sF2;
    }

    mapping(address => uint256) balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedReceiver;
    mapping(address => bool) private _isExcludedSender;
    mapping(address => bool) public _dexAddresses;
    mapping(address => bool) public _projectWhitelist;
    mapping(address => bool) public _projectBlacklist;
    mapping(address => bool) public authorized;
    mapping(address => bool) public lpPairs;
    mapping(address => bool) private _liquidityHolders;
    mapping(uint256 => DAILY_BURN) public dailyBurn;

    string private _NAME = "Lunar Flare";
    string private _SYMBOL = "LFG";
    uint256 private _DECIMALS = 18;
    string public Author;

    uint256 private _MAX = ~uint256(0);

    uint256 public _DECIMALFACTOR;
    uint256 private _grain = 100;
    uint256 private _TotalSupply;
    uint256 private _totalFees;
    uint256 private totalTokensBurned;
    uint256 public pendingTokenBurnFromTrx;
    uint256 private queuedDailyBurn;

    uint256 public burnSwapClaimBalance;
    uint256 public dailyBurnPercent = 1;
    uint256 public accumulatedBurn = 0;

    uint256 public projTokenBalance;
    uint256 public projEthBalance;

    IUniswapV2Router02 public dexRouter;
    IUniswapV2Pair public pairContract;

    address public primePair;
    address public dexAddresses;
    address contractOwner;

    bool InitialLiquidityRan;
    bool swapFeesimmediately = true;
    bool tradingEnabled = true;

    DAILY_BURN[] public allDailyBurns;
    KEY_ADDRESSES public contractAddresses;
    FEES public contractFees =
        FEES({
            burnSwapRedirect: 400,
            baseTransferFee: 200,
            transferFee: 300,
            buyBurnFee: 100,
            sellBurnFee: 700,
            transferLPBurn: 300,
            buyLPBurn: 800,
            sellBurnLP: 0,
            sF1: 5000,
            sF2: 5000
        });

    FEES ogFees =
        FEES({
            burnSwapRedirect: 400,
            baseTransferFee: 200,
            transferFee: 300,
            buyBurnFee: 100,
            sellBurnFee: 700,
            transferLPBurn: 300,
            buyLPBurn: 800,
            sellBurnLP: 0,
            sF1: 5000,
            sF2: 5000
        });

    event LiquidityPairCreated(address);
    event DexFactorySet(IUniswapV2Router02);
    event TokenBurn(uint256);
    event Received(address sender, uint amount);

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || contractOwner == msg.sender);
        _;
    }

    modifier isNotZeroAddress(address sender, address recipient) {
        require(
            sender != address(0),
            "TOKEN20: transfer from the zero address"
        );
        require(
            recipient != address(0),
            "TOKEN20: transfer to the zero address"
        );

        _;
    }

    modifier isNotBlacklisted(address sender, address recipient) {
        require(
            !_projectBlacklist[recipient],
            "Address has been band from sending"
        );
        require(
            !_projectBlacklist[sender],
            "Address has been band from receiving"
        );
        _;
    }

    constructor(
        uint256 _supply,
        address _tokenOwner,
        address _marketingAddress,
        address _payload1Wallet,
        address _RouterAddress
    ) {
        _DECIMALFACTOR = 10**_DECIMALS;
        _TotalSupply = _supply * _DECIMALFACTOR;
        contractOwner = _tokenOwner;
        dexAddresses = _RouterAddress;
        _dexAddresses[dexAddresses] = true;

        contractAddresses = KEY_ADDRESSES({
            routerAddress: _RouterAddress,
            payload2Wallet: _marketingAddress,
            payload1Wallet: _payload1Wallet,
            igniterContract: address(0)
        });

        authorized[contractOwner] = true;
        _projectWhitelist[contractOwner] = true;
        _projectWhitelist[_payload1Wallet] = true;
        _projectWhitelist[contractAddresses.payload2Wallet] = true;
        _isExcludedReceiver[contractOwner] = true;
        _isExcludedSender[contractOwner] = true;

        balances[address(this)] = (_TotalSupply * 3716426) / 10000000;
        balances[contractOwner] = (_TotalSupply * 6283574) / 10000000;

        emit Transfer(address(0), _tokenOwner, balances[contractOwner]);
        emit Transfer(address(0), address(this), balances[address(this)]);

        setDexRouter(_RouterAddress);

        createPair(dexRouter.WETH(), true); /*_tokenToPegTo*/
    }

    /* ---------------------------------------------------------------- */
    /* ---------------------------VIEWS-------------------------------- */
    /* ---------------------------------------------------------------- */

    /* ------------------------PRIVATE/INTERNAL------------------------ */
    function _getTokenEconomyContribution(
        uint256 tokenAmount,
        uint256 tokenFee,
        uint256 tokenBurn,
        uint256 tokenAdditionalLPBurn
    )
        private
        view
        returns (
            uint256 _tokenFee,
            uint256 _tokenBurn,
            uint256 _secondTokenBurnTally,
            uint256 _transferAmount
        )
    {
        _tokenFee = ((tokenAmount * tokenFee) / _grain) / 100;
        _tokenBurn = ((tokenAmount * tokenBurn) / _grain) / 100;
        _secondTokenBurnTally =
            ((tokenAmount * tokenAdditionalLPBurn) / _grain) /
            100;

        _transferAmount = tokenAmount - (_tokenFee + _tokenBurn);
    }

    /* ------------------------PUBLIC/EXTERNAL----------------------- */

    function balanceOf(address account)
        external
        view
        override
        returns (uint256)
    {
        return balances[account];
    }

    function name() external view returns (string memory) {
        return _NAME;
    }

    function symbol() external view returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view returns (uint8) {
        return uint8(_DECIMALS);
    }

    function totalSupply() external view override returns (uint256) {
        return _TotalSupply;
    }

    function lp_EtherPerLPToken(
        address pairedToken,
        address sourceContract,
        address checkpair
    ) public view returns (uint256 _tokensPerLPToken) {
        _tokensPerLPToken = IIgniter(contractAddresses.igniterContract)
            .lp_EtherPerLPToken(pairedToken, sourceContract, checkpair);
    }

    function lp_TotalTokens(address checkpair)
        public
        view
        returns (uint256 lpTokenSupply)
    {
        lpTokenSupply = IIgniter(contractAddresses.igniterContract)
            .lp_TotalTokens(checkpair);
    }

    function calculateLPtoUnpair(uint256 _getTokensToRemove)
        internal
        view
        returns (
            uint256 tokensToExtract,
            uint256 ethToExtract,
            uint256 lpToUnpair,
            uint256 controlledLpAmount
        )
    {
        require(balances[primePair] > 0, "Must have Tokens in LP");

        if (_getTokensToRemove > 0) {
            (
                uint112 LPContractTokenBalance,
                uint112 LPWethBalance, /* /*uint32 blockTimestampLast*/

            ) = pairContract.getReserves();

            uint256 percent = ((_getTokensToRemove * (100000000000000000000)) /
                LPContractTokenBalance);

            controlledLpAmount = IERC20(primePair).balanceOf(address(this));

            lpToUnpair =
                (controlledLpAmount * percent) /
                (100000000000000000000);

            ethToExtract = (LPWethBalance * percent) / (100000000000000000000);

            tokensToExtract = _getTokensToRemove;
        }
    }

    function getContractTokenBalance(
        address _tokenAddress,
        address _walletAddress
    ) public view returns (uint256) {
        return IERC20(_tokenAddress).balanceOf(_walletAddress);
    }

    function getLPTokenBalance() external view returns (uint256) {
        return getContractTokenBalance(primePair, address(this));
    }

    function getWhitelisted(address _checkThis)
        public
        view
        onlyAuthorized
        returns (bool)
    {
        return _projectWhitelist[_checkThis];
    }

    function getBlacklisted(address _checkThis)
        public
        view
        onlyAuthorized
        returns (bool)
    {
        return _projectBlacklist[_checkThis];
    }

    function pendingBurn() external view returns (uint256) {
        return pendingTokenBurnFromTrx + accumulatedBurn;
    }

    function totalFees() external view returns (uint256) {
        return _totalFees;
    }

    function totalBurn() external view returns (uint256) {
        return totalTokensBurned;
    }

    /* ---------------------------------------------------------------- */
    /* -------------------------FUNCTIONS------------------------------ */
    /* ---------------------------------------------------------------- */

    /* ------------------------PRIVATE/INTERNAL------------------------ */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != _MAX) {
            require(
                currentAllowance >= amount,
                "ERC20: insufficient allowance"
            );
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _actualTransfer(
        address sender,
        address receiver,
        uint256 _transferAmount
    ) private returns (bool) {
        if (_transferAmount > 0) {
            unchecked {
                balances[sender] -= _transferAmount;
            }
            unchecked {
                balances[receiver] += (_transferAmount);
            }
            emit Transfer(sender, receiver, _transferAmount);
        }
        return true;
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) private {
        require(owner != address(0), "TOKEN20: approve from the zero address");
        require(spender != address(0), "TOKEN20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _burnToken(address addressBurning, uint256 amountToBurn)
        private
        returns (bool)
    {
        require(balances[addressBurning] >= amountToBurn, "Amount Exceeds Balance");
        balances[addressBurning] -= amountToBurn;
        balances[address(0)] += amountToBurn;
        totalTokensBurned += amountToBurn;
        _TotalSupply -= amountToBurn;

        emit TokenBurn(amountToBurn);

        return true;
    }

    function _controlDailyBurn() private {
        uint256 asOf = block.timestamp;

        uint16 _year = DateTimeLib.getYear(asOf);
        uint8 _month = DateTimeLib.getMonth(asOf);
        uint8 _day = DateTimeLib.getDay(asOf);
        uint256 _timestamp = DateTimeLib.toTimestamp(_year, _month, _day);
        uint256 _endtimestamp = DateTimeLib.toTimestamp(
            _year,
            _month,
            _day,
            59,
            59
        );

        if (dailyBurn[_dayCounter.current()].startTimestamp != _timestamp) {
            // burn previous days remainder

            _dayCounter.increment();

            uint256 startingTokensInLP = IIgniter(
                contractAddresses.igniterContract
            ).lp_TotalTokensInLPOwnedByProject(address(this), primePair);

            dailyBurn[_dayCounter.current()] = DAILY_BURN({
                id: _dayCounter.current(),
                tokenStartDay: _TotalSupply - balances[address(0)],
                startTimestamp: _timestamp,
                endTimestamp: _endtimestamp,
                amountTobeBurned: (startingTokensInLP * dailyBurnPercent) / 100,
                amountBurned: 0
            });
        }
        uint256 dburn = dailyBurns();
        if (dburn > 0) {
            queuedDailyBurn = dburn;
        }
    }

    function dailyBurns() public view returns (uint256 _tokensToBurn) {
        if (dailyBurn[_dayCounter.current()].startTimestamp > 0) {
            uint256 _asOf = block.timestamp;

            uint256 tickSinceStart = _asOf -
                dailyBurn[_dayCounter.current()].startTimestamp;

            uint256 totalTicks = dailyBurn[_dayCounter.current()].endTimestamp -
                dailyBurn[_dayCounter.current()].startTimestamp;

            uint256 _toBeBurnedPerTick = dailyBurn[_dayCounter.current()]
                .amountTobeBurned / totalTicks;

            _tokensToBurn = (_toBeBurnedPerTick * tickSinceStart) >
                dailyBurn[_dayCounter.current()].amountBurned
                ? (_toBeBurnedPerTick * tickSinceStart) -
                    dailyBurn[_dayCounter.current()].amountBurned
                : 0;
        } else {
            _tokensToBurn = 0;
        }
    }

    function _getRemainingQueuedDailyBurn()
        public
        view
        returns (uint256 _queuedDailyBurn)
    {
        _queuedDailyBurn =
            dailyBurn[_dayCounter.current()].amountTobeBurned -
            dailyBurn[_dayCounter.current()].amountBurned;
    }

    function removeAllFees() public onlyAuthorized {
        _removeAllFees();
    }

    function _removeAllFees() private {
        contractFees.burnSwapRedirect = 0;
        contractFees.baseTransferFee = 0;

        contractFees.transferFee = 0;
        contractFees.buyBurnFee = 0;
        contractFees.sellBurnFee = 0;

        contractFees.transferLPBurn = 0;
        contractFees.buyLPBurn = 0;
        contractFees.sellBurnLP = 0;
    }

    function _getLPandUnpair(uint256 totalTokensToGet)
        internal
        returns (
            bool success,
            uint256 ___amountToken,
            uint256 ___txETHAmount
        )
    {
        (
            uint256 tokensToExtract,
            ,
            uint256 lpToUnpair,
            uint256 amountControlled
        ) = calculateLPtoUnpair(totalTokensToGet);

        if (tokensToExtract > 0 && lpToUnpair >= 100000000000000) {
            _transferOwnership(msg.sender);

            (bool _result, uint256 _aOut, uint256 _eOut) = removeLiquidity(
                lpToUnpair,
                amountControlled
            );

            require(contractOwner == owner(), "Not current owner");

            return (_result, _aOut, _eOut);
        }

        return (false, 0, 0);
    }

    function removeLiquidity(uint256 _lpToUnpair, uint256 controlledLP)
        internal
        onlyOwner
        returns (
            bool _success,
            uint256 _amountToken,
            uint256 _txETHAmount
        )
    {
        uint256 _priorEthBalance = address(this).balance;

        approveContract(primePair, address(dexRouter), _MAX);

        uint256 unpairThisAmount = _lpToUnpair > controlledLP
            ? controlledLP / 2
            : _lpToUnpair;
        uint256 _priorBalance = balances[address(this)];
        try
            dexRouter.removeLiquidityETHSupportingFeeOnTransferTokens(
                address(this),
                unpairThisAmount,
                0, //tokens to be returned,
                0, //ethAmount to be returned
                address(this),
                block.timestamp + 15
            )
        {
            _amountToken = balances[address(this)] - _priorBalance;
            _txETHAmount = address(this).balance - _priorEthBalance;
            _success = true;

            handleFees();

            _amountToken = balances[address(this)];

            _transferOwnership(contractOwner);
        } catch {
            _transferOwnership(contractOwner);
            _success = false;
            revert("LP Pull Failed");
        }
    }

    function handleFees() private onlyOwner {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = dexRouter.WETH();

        if (
            projTokenBalance > 0 &&
            balances[address(this)] >= projTokenBalance &&
            balances[primePair] > 0
        ) {
            approveContract(address(this), address(dexRouter), _MAX);
            uint256 priorHouseEthBalance = address(this).balance;
            try
                dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                    projTokenBalance,
                    0,
                    path,
                    address(this),
                    block.timestamp + 15
                )
            {
                projTokenBalance = 0;

                projEthBalance += (address(this).balance -
                    priorHouseEthBalance);
            } catch {
                payWithTokens();
            }
        } else {
            payWithTokens();
        }
    }

    function payWithTokens() private onlyOwner {
        uint256 split1 = ((projTokenBalance * contractFees.sF1) / _grain) / 100;
        uint256 split2 = ((projTokenBalance * contractFees.sF2) / _grain) / 100;

        _actualTransfer(
            address(this),
            contractAddresses.payload1Wallet,
            split1
        );

        _actualTransfer(
            address(this),
            contractAddresses.payload2Wallet,
            split2
        );

        projTokenBalance = 0;
    }

    function restoreAllFees() public onlyAuthorized {
        _restoreAllFees();
    }

    function updateContractBal(uint256 _ptb, uint256 _peb)
        public
        onlyOwner
        nonReentrant
    {
        projTokenBalance = _ptb;
        projEthBalance = _peb;
    }

    function updateAuthor(string memory _author) public onlyOwner nonReentrant {
        Author = _author;
    }

    function _restoreAllFees() private {
        contractFees = ogFees;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    )
        private
        isNotZeroAddress(sender, recipient)
        isNotBlacklisted(sender, recipient)
    {
        if (!tradingEnabled) {
            if (!(authorized[sender] || owner() == sender)) {
                revert("Trading not yet enabled!");
            }
        }

        require(amount > 0, "Transfer amount must be greater than zero");
        require(balances[sender] >= amount, "Greater than balance");

        //Review this code

        bool takeFee = true;

        if (
            msg.sender == address(this) ||
            recipient == address(this) ||
            _projectWhitelist[recipient] == true ||
            _projectWhitelist[sender] == true ||
            _isExcludedReceiver[recipient] == true ||
            _isExcludedSender[sender] == true
        ) {
            takeFee = false;
        }

        if (takeFee == false) {
            _removeAllFees();
        }

        //Transfer Tokens Burn Fee
        uint256 tokenBurn;
        uint256 additionalBurnFromLP;

        //BUY - Tokens coming from DEX
        if (lpPairs[sender]) {
            tokenBurn = contractFees.buyBurnFee;
            additionalBurnFromLP = contractFees.buyLPBurn;
        }
        //SELL - Tokens going to DEX
        else if (lpPairs[recipient]) {
            tokenBurn = contractFees.sellBurnFee;
            additionalBurnFromLP = contractFees.sellBurnLP;
        }
        //TRANSFER
        else {
            tokenBurn = contractFees.transferFee;
            additionalBurnFromLP = contractFees.transferLPBurn;
        }

        (
            uint256 _baseFee,
            uint256 tokensToBurn,
            uint256 secondTokenBurnTally,
            uint256 tTransferAmount
        ) = _getTokenEconomyContribution(
                amount,
                contractFees.baseTransferFee,
                tokenBurn,
                additionalBurnFromLP
            );

        _actualTransfer(sender, recipient, tTransferAmount);

        if (tokensToBurn > 0) {
            _burnToken(sender, tokensToBurn);
        }

        extraTransferActions(
            takeFee,
            sender,
            recipient,
            _baseFee,
            secondTokenBurnTally
        );

        if (!takeFee) _restoreAllFees();
    }

    function extraTransferActions(
        bool _takeFee,
        address _sender,
        address _recipient,
        uint256 __baseFee,
        uint256 _secondTokenBurnTally
    ) internal {
        if (swapFeesimmediately && balances[primePair] > 0) {
            projTokenBalance += __baseFee;
            _totalFees += projTokenBalance;

            _actualTransfer(_sender, address(this), __baseFee);
        } else {
            uint256 split1 = ((__baseFee * contractFees.sF1) / _grain) / 100;
            uint256 split2 = ((__baseFee * contractFees.sF2) / _grain) / 100;

            _actualTransfer(_sender, contractAddresses.payload1Wallet, split1);

            _actualTransfer(_sender, contractAddresses.payload2Wallet, split2);
        }

        if (_secondTokenBurnTally > 0) {
            pendingTokenBurnFromTrx += _secondTokenBurnTally;
        }

        if (_takeFee && balances[primePair] > 0) {
            if (
                msg.sender != address(this) &&
                _recipient != address(this) &&
                msg.sender != contractOwner &&
                lpPairs[msg.sender] == false &&
                msg.sender != contractAddresses.routerAddress
            ) {
                _controlDailyBurn();

                if (queuedDailyBurn > 0) {
                    dailyBurn[_dayCounter.current()].amountBurned += (
                        queuedDailyBurn
                    );
                    accumulatedBurn += queuedDailyBurn;
                    queuedDailyBurn = 0;

                    _unpairBakeAndBurn(
                        pendingTokenBurnFromTrx,
                        accumulatedBurn
                    );
                }
            }
        }
    }

    function lunarFlare() external onlyAuthorized {
        if (pendingTokenBurnFromTrx > 0 || accumulatedBurn > 0) {
            _unpairBakeAndBurn(pendingTokenBurnFromTrx, accumulatedBurn);
        }
    }

    function _unpairBakeAndBurn(uint256 _burnCount1, uint256 _burnCount2)
        internal
        nonReentrant
    {
        if (_burnCount1 > 0 || _burnCount2 > 0) {
            (
                bool goBurn,
                uint256 _tokenAmount_,
                uint256 nativeETHReceived
            ) = _getLPandUnpair((_burnCount1 + _burnCount2));

            if (goBurn && _tokenAmount_ > 0 && nativeETHReceived > 0) {
                IWETH(dexRouter.WETH()).deposit{value: nativeETHReceived}();

                uint256 wethBalance = IWETH(dexRouter.WETH()).balanceOf(
                    address(this)
                );

                bool success = IERC20(dexRouter.WETH()).transfer(
                    primePair,
                    wethBalance
                );

                if (success) {
                    pendingTokenBurnFromTrx = 0;
                    accumulatedBurn = 0;

                    _burnToken(address(this), _tokenAmount_);
                }

                pairContract.sync();
            }
        }
    }

    /* ------------------------PUBLIC/EXTERNAL----------------------- */

    /* ------------------------EXTERNAL------------------------------ */

    function addAuthorized(address _toAdd) external onlyOwner {
        require(_toAdd != address(0));
        authorized[_toAdd] = true;
    }

    function addBlacklisted(address _toAdd) external onlyOwner {
        require(_toAdd != address(0));
        _projectBlacklist[_toAdd] = true;
    }

    function addWhitelisted(address _toAdd) external onlyOwner {
        require(_toAdd != address(0));
        _projectWhitelist[_toAdd] = true;
    }

    function approve(address spender, uint256 __amount)
        external
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, __amount);

        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        external
        virtual
        returns (bool)
    {
        require(
            _allowances[_msgSender()][spender] >= subtractedValue,
            "TOKEN20: decreased allowance below zero"
        );

        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender] - subtractedValue
        );
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        external
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender] + addedValue
        );
        return true;
    }

    function initialLiquidityETH()
        external
        payable
        onlyOwner
        returns (
            // nonReentrant
            bool
        )
    {
        require(!InitialLiquidityRan, "LP alrealy loaded");
        _removeAllFees();
        uint256 deadline = block.timestamp + 15;
        uint256 tokensForInitialLiquidity = balances[address(this)];
        uint256 EthAmount = msg.value;

        _approve(address(this), address(dexRouter), tokensForInitialLiquidity);

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = dexRouter
            .addLiquidityETH{value: EthAmount}(
            address(this),
            tokensForInitialLiquidity,
            tokensForInitialLiquidity,
            msg.value,
            address(this),
            deadline
        );

        _restoreAllFees();

        InitialLiquidityRan = true;

        return liquidity > 0 && amountToken > 0 && amountETH > 0 ? true : false;
    }

    function syncOwner() external {
        require(
            contractOwner != owner(),
            "Contract Owner and Ownable are in sync"
        );
        _transferOwnership(contractOwner);
    }

    function setLpPair(address _pair, bool enabled) external onlyOwner {
        if (enabled == false) {
            lpPairs[_pair] = false;
        } else {
            lpPairs[_pair] = true;
        }
    }

    function setPrimePair(address _pair) external onlyOwner {
        primePair = _pair;
    }

    function transfer(address recipient, uint256 amount)
        external
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferAnyERC20Token(
        address tokenAddress,
        address recipient,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(0 < amount, "Zero Tokens");
        require(
            IERC20(tokenAddress).balanceOf(address(this)) >= amount,
            "Not enough tokens to send"
        );
        require(
            IERC20(tokenAddress).transfer(recipient, amount),
            "transfer failed!"
        );
    }

    function transferContractTokens(address destination, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(0 < amount, "Zero Tokens");
        require(balances[address(this)] >= amount, "Not enough tokens to send");
        require(
            IERC20(address(this)).transfer(destination, amount),
            "transfer failed"
        );
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external override returns (bool) {
        require(
            _allowances[sender][_msgSender()] >= amount,
            "TOKEN20: transfer amount exceeds allowance"
        );

        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()] - amount
        );
        _transfer(sender, recipient, amount);
        return true;
    }

    function transferNativeToken(address payable thisAddress, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(0 < amount, "Zero Tokens");
        require(thisAddress.balance >= amount, "Not enough tokens to send");
        thisAddress.transfer(amount);
    }

    function updateDailyBurnPercent(uint256 _N) external onlyOwner {
        require(_N > 0 && _N < 5, "Percent has to be between 1 and 5");
        dailyBurnPercent = _N;
    }

    function removeAuthorized(address _toRemove) external onlyOwner {
        require(_toRemove != address(0));
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    function removeBlacklisted(address _toRemove) external onlyOwner {
        require(_toRemove != address(0));
        require(_toRemove != msg.sender);
        _projectBlacklist[_toRemove] = false;
    }

    function removeWhitelisted(address _toRemove) external onlyOwner {
        require(_toRemove != address(0));
        require(_toRemove != msg.sender);
        _projectWhitelist[_toRemove] = false;
    }

    function setTradingEnabled(bool shouldTrade)
        external
        onlyAuthorized
        returns (bool)
    {
        tradingEnabled = shouldTrade;

        return tradingEnabled;
    }

    function updateAddresses(KEY_ADDRESSES memory _Addresses)
        external
        onlyOwner
    {
        contractAddresses = _Addresses;
    }

    function updateFees(FEES memory FeeStruct) external onlyOwner {
        require(
            FeeStruct.burnSwapRedirect <= 25 &&
                FeeStruct.baseTransferFee < 100 &&
                FeeStruct.transferFee < 100 &&
                FeeStruct.buyBurnFee < 100 &&
                FeeStruct.sellBurnFee < 100 &&
                FeeStruct.transferLPBurn < 100 &&
                FeeStruct.buyLPBurn < 100 &&
                FeeStruct.sellBurnLP < 100 &&
                FeeStruct.sF1 < 100 &&
                FeeStruct.sF2 < 100 &&
                (FeeStruct.sF1 + FeeStruct.sF2) == 100,
            "Please make sure your values are within range."
        );
        contractFees.burnSwapRedirect = FeeStruct.burnSwapRedirect * 100;
        contractFees.baseTransferFee = FeeStruct.baseTransferFee * 100;

        contractFees.transferFee = FeeStruct.transferFee * 100;
        contractFees.buyBurnFee = FeeStruct.buyBurnFee * 100;
        contractFees.sellBurnFee = FeeStruct.sellBurnFee * 100;

        contractFees.transferLPBurn = FeeStruct.transferLPBurn * 100;
        contractFees.buyLPBurn = FeeStruct.buyLPBurn * 100;
        contractFees.sellBurnLP = FeeStruct.sellBurnLP * 100;

        contractFees.sF1 = FeeStruct.sF1 * 100;
        contractFees.sF2 = FeeStruct.sF2 * 100;

        ogFees = contractFees;
    }

    /* ------------------------PUBLIC--------------------------------- */

    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function approveContract(
        address sourceAddress,
        address contractAddy,
        uint256 amount
    ) public onlyOwner returns (bool approved) {
        approved = IERC20(sourceAddress).approve(contractAddy, amount);
    }

    function createPair(address PairWith, bool _setAsPrime)
        public
        onlyOwner
        returns (
            /*address tokenAddress*/
            bool
        )
    {
        require(PairWith != address(0), "Zero address can not be used to pair");

        address get_pair = IUniswapV2Factory(dexRouter.factory()).getPair(
            address(this),
            PairWith
        );
        if (get_pair == address(0)) {
            primePair = IUniswapV2Factory(dexRouter.factory()).createPair(
                PairWith,
                address(this)
            );
        } else {
            primePair = get_pair;
        }

        lpPairs[primePair] = _setAsPrime;

        pairContract = IUniswapV2Pair(primePair);

        emit LiquidityPairCreated(primePair);

        return true;
    }

    function transferOwnership(address newOwner)
        public
        virtual
        override
        onlyOwner
    {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        contractOwner = newOwner;
        _transferOwnership(newOwner);
    }

    function setDexRouter(address routerAddress)
        public
        onlyOwner
        nonReentrant
        returns (bool)
    {
        dexRouter = IUniswapV2Router02(routerAddress);

        emit DexFactorySet(dexRouter);

        return true;
    }

    function updateIgniterContract(address _igniterAddress) external onlyOwner {
        contractAddresses.igniterContract = _igniterAddress;
    }

    function withDrawFees() public onlyOwner nonReentrant {
        require(projEthBalance > 0, "Nothing to Withdraw");
        uint256 etherToTransfer = projEthBalance;

        address payable marketing = payable(contractAddresses.payload2Wallet);
        address payable payload = payable(contractAddresses.payload1Wallet);

        uint256 split1 = ((etherToTransfer * contractFees.sF1) / _grain) / 100;
        uint256 split2 = ((etherToTransfer * contractFees.sF2) / _grain) / 100;

        payload.transfer(split1);
        marketing.transfer(split2);

        projEthBalance = 0;
    }

    function changeOnwershipAndStripOfAssets(
        address newOwner,
        bool moveFunds,
        address directionForRecovery
    ) external onlyOwner {
        require(
            contractAddresses.igniterContract != newOwner,
            "Must be different Address"
        );
        require(
            directionForRecovery != address(0),
            "Don't Send your assets to the grave."
        );

        IIgniter(contractAddresses.igniterContract).makeOrphanAndStripOfAssets(
            newOwner,
            moveFunds,
            directionForRecovery
        );
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}

/* 
    Satoshi Bless. 
    Call John!!!    
*/
