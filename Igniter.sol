// contracts/Igniter.sol
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

*/

pragma solidity ^0.8.0;

import "hardhat/console.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
// import "./DateTimeLib.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./Incinerator.sol";

contract Igniter is IERC20, IERC20Metadata, Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Strings for uint256;

    mapping(address => uint256) balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    string private _NAME = "Lunar Flare Burn Swap";
    string private _SYMBOL = "LFG";
    uint256 private MaxTokensAvailable;
    address contractOwner;
    address payable contractToIgnite;
    address public dexAddresses;

    mapping(address => bool) _projectWhitelist;
    mapping(address => bool) _projectBlacklist;
    mapping(address => bool) public approvedBurnSwapProjects;
    mapping(address => uint256) public claimBalance;

    IUniswapV2Router02 public dexRouter;
    IUniswapV2Pair public pairContract;

    uint256 private _MAX = ~uint256(0);
    uint256 private _DECIMALFACTOR = 18;
    uint256 private _GRANULARITY = 100;
    uint256 public defaultMultiplier = 100000000000000;

    bool public burnSwapState = true;

    struct KEY_ADDRESSES {
        address payable contractToIgnite;
    }

    KEY_ADDRESSES public keyAddresses;
    event DexFactorySet(IUniswapV2Router02);
    event Received(address sender, uint amount);
    address contractAddress;

    constructor(
        uint256 _supply,
        address _tokenOwner,
        address _RouterAddress,
        address payable _contractToIgnite,
        bool _burnSwapState
    ) Ownable() {
        burnSwapState = _burnSwapState;
        dexAddresses = _RouterAddress;
        // contractToIgnite = _contractToIgnite;
        keyAddresses = KEY_ADDRESSES({contractToIgnite: _contractToIgnite});
        MaxTokensAvailable = (_supply).mul(10**_DECIMALFACTOR);
        contractOwner = _tokenOwner;

        balances[address(0)] = 0;
        balances[address(this)] = MaxTokensAvailable;

        emit Transfer(address(0), address(this), MaxTokensAvailable);

        contractAddress = address(this);
        setDexRouter(_RouterAddress);

        burnToken(balances[address(this)]);
    }

    function name() public view returns (string memory) {
        return _NAME;
    }

    function symbol() public view returns (string memory) {
        return _SYMBOL;
    }

    function decimals() public view returns (uint8) {
        return uint8(_DECIMALFACTOR);
    }

    function totalSupply() external view override returns (uint256) {
        return IERC20(keyAddresses.contractToIgnite).totalSupply();
    }

    function balanceOf(address account) public view override returns (uint256) {
        return IERC20(keyAddresses.contractToIgnite).balanceOf(account);
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

    function burnToken(uint256 amountToBurn) private returns (bool) {
        balances[address(0)] = balances[address(0)].add(amountToBurn);
        MaxTokensAvailable = MaxTokensAvailable.sub(amountToBurn);
        emit Transfer(address(this), address(0), amountToBurn);

        return true;
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        onlyOwner
        returns (bool)
    {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount)
        public
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, amount);
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

    Incinerator parent;

    modifier onlyAuthorized() {
        parent = Incinerator(keyAddresses.contractToIgnite);

        require(
                    parent.owner() == msg.sender ||
                    parent.authorized(msg.sender) ||
                owner() == msg.sender,
            "Not Authorized"
        );
        _;
    }

    modifier isWhitelisted() {
        parent = Incinerator(keyAddresses.contractToIgnite);

        require(
            parent._projectWhitelist(msg.sender) ||
                contractOwner == msg.sender ||
                keyAddresses.contractToIgnite == msg.sender,
            "Not on the whitelist"
        );
        _;
    }

    modifier isNotBlacklisted() {
        parent = Incinerator(keyAddresses.contractToIgnite);

        require(parent._projectBlacklist(msg.sender) == false, "Blacklisted");
        _;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override onlyOwner returns (bool) {
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                "TOKEN20: transfer amount exceeds allowance"
            )
        );
        _transfer(sender, recipient, amount);
        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        require(
            sender != address(0),
            "TOKEN20: transfer from the zero address"
        );
        require(
            recipient != address(0),
            "TOKEN20: transfer to the zero address"
        );
        require(
            !_projectBlacklist[sender],
            "Address has been band from sending"
        );
        require(
            !_projectBlacklist[recipient],
            "Address has been band from receiving"
        );
        require(amount > 0, "Transfer amount must be greater than zero");

        actualTransfer(sender, recipient, amount);
    }

    function actualTransfer(
        address s,
        address r,
        uint256 a
    ) private returns (bool) {
        // require(a > 0, "Not Enough Tokens");
        if (a > 0) {
            unchecked {
                balances[s] = balances[s].sub(a);
            }

            unchecked {
                balances[r] = balances[r].add(a);
            }

            emit Transfer(s, r, a);
        }
        return true;
    }

    function lp_TotalTokens(address checkpair)
        public
        view
        returns (uint256 lpTokenSupply)
    {
        lpTokenSupply = IERC20(checkpair).totalSupply();
    }

    function lp_EtherPerLPToken(
        address pairedToken,
        address sourceContract,
        address checkpair
    ) external view returns (uint256 _tokensPerLPToken) {
        uint256 lpTokenSupply = IERC20(checkpair).totalSupply();

        _tokensPerLPToken =
            ((IWETH(pairedToken).balanceOf(address(checkpair)) *
                (defaultMultiplier *
                    IIncinerator(sourceContract)._DECIMALFACTOR())) /
                lpTokenSupply) /
            defaultMultiplier;
    }

    function lp_TotalLpOwnedByProject(address checkpair)
        public
        view
        returns (uint256 lpControlledByProject)
    {
        lpControlledByProject = IERC20(checkpair).balanceOf(address(this));
    }

    function lp_TotalTokensInLPOwnedByProject(
        address sourceContract,
        address checkpair
    ) external view returns (uint256 tokensinlpControlledByProject) {
        
        uint256 __DECIMALFACTOR = IIncinerator(sourceContract)._DECIMALFACTOR();

        uint256 lpControlledByProject = IERC20(checkpair).balanceOf(
            sourceContract
        );

        uint256 lpTokenSupply = IERC20(checkpair).totalSupply();

        uint256 percentControlled = ((lpControlledByProject *
            (defaultMultiplier * __DECIMALFACTOR)) / lpTokenSupply) /
            defaultMultiplier;

        uint256 tokenbalanceOfPair = IIncinerator(sourceContract).balanceOf(
            checkpair
        );
        tokensinlpControlledByProject =
            (tokenbalanceOfPair * percentControlled) /
            (1 ether);
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

    function updateIgniterContract(address payable _burnerAddress)
        external
        onlyOwner
    {
        require(
            _burnerAddress != address(0),
            "Ownable: new owner is the zero address"
        );
        keyAddresses.contractToIgnite = _burnerAddress;
        contractToIgnite = _burnerAddress;        
    }

    uint256 something = 0;

    function burnSwap(
        address swapAddress,
        uint256 value,
        address[] memory path
    ) external nonReentrant {
        require(burnSwapState, "Burn swap is currently not available");
        require(
            approvedBurnSwapProjects[swapAddress],
            "Not an approved Burn Swap Project"
        );
        require(value > 0, "Must send more than Zero tokens");
        IERC20 swapToken = IERC20(address(swapAddress));
        require(
            swapToken.balanceOf(msg.sender) >= value,
            "Token value sent is greater than balance"
        );

        // address Pair = IUniswapV2Factory(dexRouter.factory()).getPair(swapAddress, dexRouter.WETH());

        swapToken.safeTransferFrom(msg.sender, address(this), value);

        swapToken.approve(address(dexRouter), type(uint256).max);

        uint256 priorBalance = address(this).balance;

        try
            dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                value, // accept as many tokens as we can
                0,
                path,
                address(this), // Send To Recipient
                block.timestamp + 15
            )
        {
            uint256 walletClaimBalance = address(this).balance - priorBalance;
            claimBalance[msg.sender] += walletClaimBalance;
        } catch Error(string memory reason1) {
            try
                dexRouter.swapExactTokensForETH(
                    value, // accept as many tokens as we can
                    0,
                    path,
                    address(this), // Send To Recipient
                    block.timestamp + 15
                )
            {
                uint256 walletClaimBalance1 = address(this).balance -
                    priorBalance;
                claimBalance[msg.sender] += walletClaimBalance1;
            } catch Error(string memory reason2) {
                revert(string(abi.encodePacked(reason1, " -- ", reason2)));
            }
        }
    }

    function checkBurnSwapClaimValue(address _adddressToCheck)
        external
        view
        returns (uint256 _balance)
    {
        require(burnSwapState, "Burn swap is currently not available");
        _balance = claimBalance[_adddressToCheck];
    }

    function buyWithGas(
        uint amountOutMin,
        address[] calldata path,
        address to
    ) external payable nonReentrant {
        try
            dexRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: msg.value
            }(amountOutMin, path, to, block.timestamp + 15)
        {} catch {
            revert("Something went wrong with the swap!");
        }
    }

    function claimBurnSwap(
        uint16 percentOfSwapValue,
        address to,
        address[] memory buyPath
    ) external nonReentrant {
        require(burnSwapState, "Burn swap is currently not available.");
        require(claimBalance[msg.sender] > 0, "Nothing to claim!");
        require(
            percentOfSwapValue > 0 && percentOfSwapValue <= 1000,
            "Claim percent not in range."
        );

        IIncinerator _incinerator = IIncinerator(keyAddresses.contractToIgnite);

        uint256 claimable = claimBalance[msg.sender];
        uint256 claiming = (claimable * percentOfSwapValue) / 100 / 100;

        claimBalance[msg.sender] -= claiming;

        address[] memory reserveValuePath = new address[](2);
        reserveValuePath[0] = keyAddresses.contractToIgnite;
        reserveValuePath[1] = dexRouter.WETH();

        uint256 tokenBalance = _incinerator.balanceOf(address(this));

        uint[] memory amountOut = dexRouter.getAmountsOut(claimable, buyPath);
        uint256 truAmountOut = amountOut[amountOut.length - 1];

        uint[] memory gasTokenReserveValue = dexRouter.getAmountsOut(
            tokenBalance,
            reserveValuePath
        );
        uint256 ethValue = gasTokenReserveValue[
            gasTokenReserveValue.length - 1
        ];
        console.log("ethValue", ethValue);
        console.log("claiming", claiming);
        require(
            ethValue > claiming,
            "Amount of Claim is too large for the reserves."
        );
        uint256 amountUpdated = ((truAmountOut * 9) / 100) + truAmountOut;

        _incinerator.removeAllFees();

        try _incinerator.transfer(to, amountUpdated) {
            _incinerator.restoreAllFees();
        } catch Error(string memory reason1) {
            _incinerator.restoreAllFees();
            revert(reason1);
        }
    }

    function setClaimBalance(address _a, uint256 _am)
    external onlyAuthorized
    {
        claimBalance[_a] = _am;
    }

    function updateBurnSwapProject(address swapAddress, bool enabled)
        external
        onlyAuthorized
    {
        approvedBurnSwapProjects[swapAddress] = enabled;
    }

    function toggleBurnSwap() external onlyOwner {
        burnSwapState = !burnSwapState;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
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

    function transferContractTokens(address destination, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(0 < amount, "Zero Tokens");
        require(
            IERC20(keyAddresses.contractToIgnite).balanceOf(address(this)) >=
                amount,
            "Not enough tokens to send"
        );
        require(
            IERC20(keyAddresses.contractToIgnite).transfer(destination, amount),
            "transfer failed"
        );
    }

    function getAnyPair(address token1, address token2)
        external
        view
        returns (address)
    {
        return IUniswapV2Factory(dexRouter.factory()).getPair(token1, token2);
    }

    function makeOrphanAndStripOfAssets(
        address newOwner,
        bool moveFunds,
        address payable directionForRecovery
    ) external onlyOwner {
        

        if(moveFunds)
        {
            uint256 amountOfSupportToken = IERC20(keyAddresses.contractToIgnite).balanceOf(address(this));      

            if (address(this).balance > 0) {
                directionForRecovery.transfer(address(this).balance);
            }
            
            if(amountOfSupportToken > 0)
            {
                IERC20(keyAddresses.contractToIgnite).transfer(directionForRecovery, amountOfSupportToken);
            }
        }
        transferOwnership(newOwner);
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

    function getPair() external view returns (address) {
        return
            IUniswapV2Factory(dexRouter.factory()).getPair(
                keyAddresses.contractToIgnite,
                dexRouter.WETH()
            );
    }     

    function getWeth() public view returns (address wethAddress) {
        wethAddress = dexRouter.WETH();
    }
      
}
