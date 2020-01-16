pragma  solidity 0.5.11;

import "./WithdrawableV5.sol";
import "./UtilsV5.sol";
import "./ReentrancyGuard.sol";
import "./IKyberNetwork.sol";
import "./IKyberReserve.sol";
import "./IFeeHandler.sol";


interface IExpectedRate {
    function getExpectedRate(IERC20 src, IERC20 dest, uint srcQty) external view
        returns (uint expectedRateNoFees, uint expectedRateNetworkFees, uint expectedRateAllFees);
}


////////////////////////////////////////////////////////////////////////////////////////////////////////
/// @title Kyber Network main contract
contract KyberNetwork is Withdrawable, Utils, IKyberNetwork, ReentrancyGuard {

    bytes constant PERM_HINT = "PERM"; //for backwards compatibility
    uint  constant PERM_HINT_GET_RATE = 1 << 255; //for backwards compatibility
    uint            public negligibleRateDiff = 10; // basic rate steps will be in 0.01%
    IExpectedRate   public expectedRateContract;
    IFeeHandler     public feeHandlerContract;

    uint            public takerFeeData; // will include feeBps and expiry block
    address         public kyberNetworkProxyContract;
    uint            maxGasPriceValue = 50 * 1000 * 1000 * 1000; // 50 gwei
    bool            isEnabled = false; // network is enabled
    
    mapping(bytes32=>uint) public infoFields; // this is only a UI field for external app.

    IKyberReserve[] public reserves;
    mapping(address=>uint) public reserveAddressToId;
    mapping(uint=>address[]) public reserveIdToAddresses;
    mapping(address=>bool) public isFeePayingReserve;
    mapping(address=>IKyberReserve[]) public reservesPerTokenSrc; //reserves supporting token to eth
    mapping(address=>IKyberReserve[]) public reservesPerTokenDest;//reserves support eth to token
    mapping(address=>address) public reserveRebateWallet;

    constructor(address _admin) public 
        Withdrawable(_admin)
    { /* empty body */ }

    event EtherReceival(address indexed sender, uint amount);

    function() external payable {
        emit EtherReceival(msg.sender, msg.value);
    }

    // the new trade with hint
    function tradeWithHintAndFee(address payable trader, IERC20 src, uint srcAmount, IERC20 dest, address payable destAddress,
        uint maxDestAmount, uint minConversionRate, address payable platformWallet, uint platformFeeBps, bytes calldata hint)
        external payable
        returns(uint destAmount)
    {
        TradeData memory tradeData;

        tradeData.input.trader = trader;
        tradeData.input.src = src;
        tradeData.input.srcAmount = srcAmount;
        tradeData.input.dest = dest;
        tradeData.input.destAddress = destAddress;
        tradeData.input.maxDestAmount = maxDestAmount;
        tradeData.input.minConversionRate = minConversionRate;
        tradeData.input.platformWallet = platformWallet;
        tradeData.input.platformFeeBps = platformFeeBps;

        parseTradeDataHint(tradeData, hint);
        tradeData.takerFeeBps = getAndUpdateTakerFee();
        
        return trade(tradeData);
    }

     // backward compatible
    function tradeWithHint(address trader, ERC20 src, uint srcAmount, ERC20 dest, address destAddress,
        uint maxDestAmount, uint minConversionRate, address walletId, bytes calldata hint)
        external payable returns(uint destAmount)
    {
        TradeData memory tradeData;

        tradeData.input.trader = address(uint160(trader));
        tradeData.input.src = src;
        tradeData.input.srcAmount = srcAmount;
        tradeData.input.dest = dest;
        tradeData.input.destAddress = address(uint160(destAddress));
        tradeData.input.maxDestAmount = maxDestAmount;
        tradeData.input.minConversionRate = minConversionRate;
        tradeData.input.platformWallet = walletId;
        tradeData.input.platformFeeBps = 0;

        parseTradeDataHint(tradeData, hint);
        tradeData.takerFeeBps = getAndUpdateTakerFee();
        
        return trade(tradeData);
    }

    event AddReserveToNetwork(address indexed reserve, uint indexed reserveId, bool add, address indexed rebateWallet);

    /// @notice can be called only by operator
    /// @dev add or deletes a reserve to/from the network.
    /// @param reserve The reserve address.
    function addReserve(address reserve, uint reserveId, bool isFeePaying, address wallet) public onlyOperator returns(bool) {
        require(reserveIdToAddresses[reserveId].length == 0);
        require(reserveAddressToId[reserve] == uint(0));
        
        reserveAddressToId[reserve] = reserveId;

        reserveIdToAddresses[reserveId][0] = reserve;
        isFeePayingReserve[reserve] = isFeePaying;
        
        reserves.push(IKyberReserve(reserve));

        reserveRebateWallet[reserve] = wallet;

        emit AddReserveToNetwork(reserve, reserveId, true, wallet);

        return true;
    }

    event RemoveReserveFromNetwork(IKyberReserve reserve, uint indexed reserveId);

    /// @notice can be called only by operator
    /// @dev removes a reserve from Kyber network.
    /// @param reserve The reserve address.
    /// @param startIndex to search in reserve array.
    function removeReserveWithIndex(IKyberReserve reserve, uint startIndex) public onlyOperator returns(bool) {

        require(reserveAddressToId[address(reserve)] != uint(0), "corresponding reserve id is zero");
        
        uint reserveIndex = 2 ** 255;
        uint reserveId = reserveAddressToId[address(reserve)];
        
        for (uint i = startIndex; i < reserves.length; i++) {
            if(reserves[i] == reserve) {
                reserveIndex = i;
                break;
            }
        }
        
        reserves[reserveIndex] = reserves[reserves.length - 1];
        reserves.length--;

        reserveIdToAddresses[reserveId][reserveIdToAddresses[reserveId].length] = reserveIdToAddresses[reserveId][0];
        reserveIdToAddresses[reserveId][0] = address(0);
        
        emit RemoveReserveFromNetwork(reserve, reserveId);

        return true;
    }

    function removeReserve(IKyberReserve reserve) public onlyOperator returns(bool) {
        return removeReserveWithIndex(reserve, 0);
    }
    
    event ListReservePairs(address indexed reserve, IERC20 src, IERC20 dest, bool add);

    /// @notice can be called only by operator
    /// @dev allow or prevent a specific reserve to trade a pair of tokens
    /// @param reserve The reserve address.
    /// @param token token address
    /// @param ethToToken will it support ether to token trade
    /// @param tokenToEth will it support token to ether trade
    /// @param add If true then list this pair, otherwise unlist it.
    function listPairForReserve(address reserve, IERC20 token, bool ethToToken, bool tokenToEth, bool add)
        public
        onlyOperator
        returns(bool)
    {
        require(reserveAddressToId[reserve] != uint(0));

        if (ethToToken) {
            listPairs(IKyberReserve(reserve), token, false, add);

            emit ListReservePairs(reserve, ETH_TOKEN_ADDRESS, token, add);
        }

        if (tokenToEth) {
            listPairs(IKyberReserve(reserve), token, true, add);

            if (add) {
                require(token.approve(reserve, 2**255)); // approve infinity
            } else {
                require(token.approve(reserve, 0));
            }

            emit ListReservePairs(reserve, token, ETH_TOKEN_ADDRESS, add);
        }

        setDecimals(token);

        return true;
    }

    event ExpectedRateContractSet(IExpectedRate newContract, IExpectedRate currentContract);

    function setExpectedRate(IExpectedRate expectedRate) public onlyAdmin {
        require(expectedRate != IExpectedRate(0));

        emit ExpectedRateContractSet(expectedRate, expectedRateContract);
        expectedRateContract = expectedRate;
    }

    event FeeHandlerContractSet(IFeeHandler newContract, IFeeHandler currentContract);

    function setFeeHandler(IFeeHandler feeHandler) public onlyAdmin {
        require(feeHandler != IFeeHandler(0));

        emit FeeHandlerContractSet(feeHandler, feeHandlerContract);
        feeHandlerContract = feeHandler;
    }

    event KyberNetworkParamsSet(uint maxGasPrice, uint negligibleRateDiff);

    function setParams(
        uint                  _maxGasPrice,
        uint                  _negligibleRateDiff
    )
        public
        onlyAdmin
    {
        require(_negligibleRateDiff <= 100 * 100); // at most 100%

        maxGasPriceValue = _maxGasPrice;
        negligibleRateDiff = _negligibleRateDiff;
        emit KyberNetworkParamsSet(maxGasPriceValue, negligibleRateDiff);
    }

    event KyberNetworkSetEnable(bool isEnabled);

    function setEnable(bool _enable) public onlyAdmin {
        if (_enable) {
            require(feeHandlerContract != IFeeHandler(0));
            require(expectedRateContract != IExpectedRate(0));
            require(kyberNetworkProxyContract != address(0));
        }
        isEnabled = _enable;

        emit KyberNetworkSetEnable(isEnabled);
    }

    function setInfo(bytes32 field, uint value) public onlyOperator {
        infoFields[field] = value;
    }

    event KyberProxySet(address proxy, address sender);

    function setKyberProxy(address networkProxy) public onlyAdmin {
        require(networkProxy != address(0));
        kyberNetworkProxyContract = networkProxy;
        emit KyberProxySet(kyberNetworkProxyContract, msg.sender);
    }

    /// @dev returns number of reserves
    /// @return number of reserves
    function getNumReserves() public view returns(uint) {
        return reserves.length;
    }

    /// @notice should be called off chain
    /// @dev get an array of all reserves
    /// @return An array of all reserves
    function getReserves() public view returns(IKyberReserve[] memory) {
        return reserves;
    }

    function maxGasPrice() public view returns(uint) {
        return maxGasPriceValue;
    }

    function updateTakerFee() public returns(uint takerFeeBps) {
        takerFeeBps = getAndUpdateTakerFee();
    }
    
    //backward compatible
    function getExpectedRate(ERC20 src, ERC20 dest, uint srcQty) external view
        returns (uint expectedRate, uint worstRate)
    {
        // require(expectedRateContract != IExpectedRate(0));
        if (src == dest) return (0, 0);
        uint qty = srcQty & ~PERM_HINT_GET_RATE;
        
        TradeData memory tradeData;
        bytes memory hint;
        
        tradeData.input.src = src;
        tradeData.input.srcAmount = qty;
        tradeData.input.dest = dest;
        tradeData.input.maxDestAmount = 2 ** 255;
        parseTradeDataHint(tradeData, hint);
        tradeData.takerFeeBps = getTakerFee();

        findRatesAndAmounts(src, dest, qty, tradeData);
        
        expectedRate = tradeData.rateWithNetworkFee;
        worstRate = expectedRate * 97 / 100; // backward compatible formula
    }

    // new APIs
    function getExpectedRateWithHintAndFee(IERC20 src, IERC20 dest, uint srcQty, uint platformFeeBps, bytes calldata hint) 
        external view
        returns (uint expectedRateNoFees, uint expectedRateAfterNetworkFees, uint expectedRateAfterAllFees)
    {
        require(expectedRateContract != IExpectedRate(0));
        
        if (src == dest) return (0, 0, 0);
        
        TradeData memory tradeData;
        
        tradeData.input.src = src;
        tradeData.input.srcAmount = srcQty;
        tradeData.input.dest = dest;
        tradeData.input.maxDestAmount = 2 ** 255;
        tradeData.input.platformFeeBps = platformFeeBps;
        parseTradeDataHint(tradeData, hint);
        tradeData.takerFeeBps = getTakerFee();
        
        findRatesAndAmounts(src, dest, srcQty, tradeData);
        
        expectedRateNoFees = calcRateFromQty(srcQty, tradeData.destAmountNoFee, tradeData.tokenToEth.decimals, tradeData.ethToToken.decimals);
        expectedRateAfterNetworkFees = tradeData.rateWithNetworkFee;
        expectedRateAfterAllFees = calcRateFromQty(srcQty, tradeData.actualDestAmount, tradeData.tokenToEth.decimals, tradeData.ethToToken.decimals);
    }

    function enabled() public view returns(bool) {
        return isEnabled;
    }

    function info(bytes32 field) public view returns(uint) {
        return infoFields[field];
    }

    function getAllRatesForToken(IERC20 token, uint optionalAmount) public view
        returns(IKyberReserve[] memory buyReserves, uint[] memory buyRates, IKyberReserve[] memory sellReserves, uint[] memory sellRates)
    {
        uint amount = optionalAmount > 0 ? optionalAmount : 1000;
        IERC20 ETH = ETH_TOKEN_ADDRESS;

        buyReserves = reservesPerTokenDest[address(token)];
        buyRates = new uint[](buyReserves.length);

        uint i;
        for (i = 0; i < buyReserves.length; i++) {
            buyRates[i] = (IKyberReserve(buyReserves[i])).getConversionRate(ETH, token, amount, block.number);
        }

        sellReserves = reservesPerTokenSrc[address(token)];
        sellRates = new uint[](sellReserves.length);

        for (i = 0; i < sellReserves.length; i++) {
            sellRates[i] = (IKyberReserve(sellReserves[i])).getConversionRate(token, ETH, amount, block.number);
        }
    }
   
    function listPairs(IKyberReserve reserve, IERC20 token, bool isTokenToEth, bool add) internal {
        uint i;
        IKyberReserve[] storage reserveArr = reservesPerTokenDest[address(token)];

        if (isTokenToEth) {
            reserveArr = reservesPerTokenSrc[address(token)];
        }

        for (i = 0; i < reserveArr.length; i++) {
            if (reserve == reserveArr[i]) {
                if (add) {
                    break; //already added
                } else {
                    //remove
                    reserveArr[i] = reserveArr[reserveArr.length - 1];
                    reserveArr.length--;
                    break;
                }
            }
        }

        if (add && i == reserveArr.length) {
            //if reserve wasn't found add it
            reserveArr.push(reserve);
        }
    }

    struct BestReserveInfo {
        uint index;
        uint destAmount;
    }

    /* solhint-disable code-complexity */
    // Regarding complexity. Below code follows the required algorithm for choosing a reserve.
    //  It has been tested, reviewed and found to be clear enough.
    //@dev this function always src or dest are ether. can't do token to token
    //TODO: document takerFee
    function searchBestRate(IKyberReserve[] memory reserveArr, IERC20 src, IERC20 dest, uint srcAmount, uint takerFee)
        public
        view
        returns(IKyberReserve reserve, uint, bool isPayingFees)
    {
        //use destAmounts for comparison, but return the best rate
        BestReserveInfo memory bestReserve;
        uint numRelevantReserves = 1; // assume always best reserve will be relevant

        //return 1 for ether to ether, or if empty reserve array is passed
        if (src == dest || reserveArr.length == 0) return (IKyberReserve(address(0)), PRECISION, false);

        if (reserveArr.length == 0) return (reserves[bestReserve.index], 0, false);

        uint[] memory rates = new uint[](reserveArr.length);
        uint[] memory reserveCandidates = new uint[](reserveArr.length);
        uint destAmount;
        uint srcAmountWithFee;

        for (uint i = 0; i < reserveArr.length; i++) {
            reserve = reserveArr[i];
            //list all reserves that support this token.
            isPayingFees = isFeePayingReserve[address(reserve)];
            //for ETH -> token paying reserve, takerFee is specified in amount
            srcAmountWithFee = ((src == ETH_TOKEN_ADDRESS) && isPayingFees) ? srcAmount - takerFee : srcAmount;
            rates[i] = reserve.getConversionRate(
                src,
                dest,
                srcAmountWithFee,
                block.number);

            destAmount = srcAmountWithFee * rates[i] / PRECISION;
             //for token -> ETH paying reserve, takerFee is specified in bps
            destAmount = (dest == ETH_TOKEN_ADDRESS && isPayingFees) ? destAmount * (BPS - takerFee) / BPS : destAmount;

            if (destAmount > bestReserve.destAmount) {
                //best rate is highest rate
                bestReserve.destAmount = destAmount;
                bestReserve.index = i;
            }
        }

        if(bestReserve.destAmount == 0) return (reserves[bestReserve.index], 0, false);
        
        reserveCandidates[0] = bestReserve.index;
        
        // if this reserve pays fee its actual rate is less. so smallestRelevantRate is smaller.
        bestReserve.destAmount = bestReserve.destAmount * BPS / (10000 + negligibleRateDiff);

        for (uint i = 0; i < reserveArr.length; i++) {

            if (i == bestReserve.index) continue;

            isPayingFees = isFeePayingReserve[address(reserve)];
            srcAmountWithFee = ((src == ETH_TOKEN_ADDRESS) && isPayingFees) ? srcAmount - takerFee : srcAmount;
            destAmount = srcAmountWithFee * rates[i] / PRECISION;
            destAmount = (dest == ETH_TOKEN_ADDRESS && isPayingFees) ? destAmount * (BPS - takerFee) / BPS : destAmount;

            if (destAmount > bestReserve.destAmount) {
                reserveCandidates[numRelevantReserves++] = i;
            }
        }

        if (numRelevantReserves > 1) {
            //when encountering small rate diff from bestRate. draw from relevant reserves
            bestReserve.index = reserveCandidates[uint(blockhash(block.number-1)) % numRelevantReserves];
        } else {
            bestReserve.index = reserveCandidates[0];
        }
        isPayingFees = isFeePayingReserve[address(reserveArr[bestReserve.index])];
        return (reserveArr[bestReserve.index], rates[bestReserve.index], isPayingFees);
    }

    struct TradingReserves {
        IKyberReserve[] addresses;
        uint[] rates; // rate per chosen reserve for token to eth
        bool[] isPayingFees;
        uint[] splitValuesBps;
        uint decimals;
    }

    struct TradeInput {
        address payable trader;
        IERC20 src;
        uint srcAmount;
        IERC20 dest;
        address payable destAddress;
        uint maxDestAmount;
        uint minConversionRate;
        address platformWallet;
        uint platformFeeBps;
    }
    
    // enable up to x reserves for token to Eth and x for eth to token
    // if not hinted reserves use 1 reserve for each trade side
    struct TradeData {
        
        TradeInput input;
        
        TradingReserves tokenToEth;
        TradingReserves ethToToken;
        
        uint tradeWei;
        uint networkFeeWei;
        uint platformFeeWei;

        uint takerFeeBps;
        
        uint numFeePayingReserves;
        uint feePayingReservesBps; // what part of this trade is fee paying. for token to token - up to 200%
        uint takePlatformFeeBps;
        
        uint destAmountNoFee;
        uint destAmountWithNetworkFee;
        uint actualDestAmount; // all fees

        // TODO: do we need to save rate locally. seems dest amounts enough.
        // uint rateNoFee;
        uint rateWithNetworkFee;
        // uint rateWithAllFees;
    }

  // accumulate fee wei
    function findRatesAndAmounts(IERC20 src, IERC20 dest, uint srcAmount, TradeData memory tradeData) 
        internal view
    // function should set all TradeData so it can later be used without any ambiguity
    {
        // assume TradingReserves stores the reserves to be iterated over (meaning masking has been applied
        findRatesAndAmountsTokenToEth(src, srcAmount, tradeData);

        //TODO: see if this need to be shifted below instead
        if (tradeData.tradeWei == 0) {
            tradeData.rateWithNetworkFee = 0;
            return;
        }

        //if split reserves, add bps for ETH -> token
        if (tradeData.tokenToEth.splitValuesBps.length > 1) {
            for (uint i = 0; i < tradeData.ethToToken.addresses.length; i++) {
                if (tradeData.ethToToken.isPayingFees[i]) {
                    tradeData.feePayingReservesBps += tradeData.ethToToken.splitValuesBps[i];
                    tradeData.numFeePayingReserves ++;
                }
            }
        }

        //fee deduction
        //no fee deduction occurs for masking of ETH -> token reserves, or if no ETH -> token reserve was specified
        tradeData.networkFeeWei = tradeData.tradeWei * tradeData.takerFeeBps * tradeData.feePayingReservesBps / (BPS * BPS);
        tradeData.platformFeeWei = tradeData.tradeWei * tradeData.input.platformFeeBps / BPS;

        //change to if condition instead
        require(tradeData.tradeWei >= (tradeData.networkFeeWei + tradeData.platformFeeWei), "fees exceed trade amount");
        findRatesAndAmountsEthToToken(
            dest,
            tradeData.tradeWei,
            tradeData.tradeWei - tradeData.networkFeeWei,
            tradeData.tradeWei - tradeData.networkFeeWei - tradeData.platformFeeWei,
            tradeData
        );

        // calc final rate
        tradeData.rateWithNetworkFee = calcRateFromQty(srcAmount, tradeData.destAmountWithNetworkFee, tradeData.tokenToEth.decimals, tradeData.ethToToken.decimals);
    }

    function findRatesAndAmountsTokenToEth(IERC20 src, uint srcAmount, TradeData memory tradeData) internal view {
        IKyberReserve reserve;
        uint splitAmount;
        uint srcAmountSoFar;
        bool isPayingFees;

        // token to Eth
        ///////////////
        // if split reserves, find rates
        // can consider parsing enum hint type into tradeData for easy identification of splitHint. Or maybe just boolean flag
        if (tradeData.tokenToEth.splitValuesBps.length > 1) {
            for (uint i = 0; i < tradeData.tokenToEth.addresses.length; i++) {
                reserve = tradeData.tokenToEth.addresses[i];
                //calculate split and corresponding trade amounts
                splitAmount = (i == tradeData.tokenToEth.splitValuesBps.length - 1) ? (srcAmount - srcAmountSoFar) : tradeData.tokenToEth.splitValuesBps[i] * srcAmount / BPS;
                srcAmountSoFar += splitAmount;
                tradeData.tokenToEth.rates[i] = reserve.getConversionRate(src, ETH_TOKEN_ADDRESS, splitAmount, block.number);
                tradeData.tradeWei += calcDstQty(splitAmount, tradeData.tokenToEth.decimals, ETH_DECIMALS, tradeData.tokenToEth.rates[i]);

                //account for fees
                if (tradeData.tokenToEth.isPayingFees[i]) {
                    tradeData.feePayingReservesBps += tradeData.tokenToEth.splitValuesBps[i];
                    tradeData.numFeePayingReserves ++;
                }
            }
        } else {
            // else find best rate
            (reserve, tradeData.tokenToEth.rates[0], isPayingFees) = searchBestRate(tradeData.tokenToEth.addresses, src, ETH_TOKEN_ADDRESS, srcAmount, tradeData.takerFeeBps);
            // save into tradeData
            tradeData.tokenToEth.addresses[0] = reserve;
            tradeData.tradeWei = calcDstQty(srcAmount, tradeData.tokenToEth.decimals, ETH_DECIMALS, tradeData.tokenToEth.rates[0]);
            tradeData.tokenToEth.splitValuesBps[0] = BPS; //max percentage amount

            //account for fees
            if (isPayingFees) {
                tradeData.feePayingReservesBps = BPS; //max percentage amount for token -> ETH
                tradeData.numFeePayingReserves ++;
            }
        }
    }

    function findRatesAndAmountsEthToToken(
        IERC20 dest,
        uint tradeWei,
        uint tradeWeiMinusNetworkFee,
        uint tradeWeiMinusNetworkCustomFees,
        TradeData memory tradeData
    )
        internal
        view
    {
        IKyberReserve reserve;
        uint rate;
        uint amountSoFarNoFee;
        uint amountSoFarWithNetworkFee;
        uint amountSoFarWithNetworkAndCustomFee;
        uint splitAmount;
        bool isPayingFees;
        
        // Eth to token
        ///////////////
        // if hinted reserves, find rates and save.
        if (tradeData.ethToToken.splitValuesBps.length > 1) {
            //reset amountSoFarNoFee
            amountSoFarNoFee = 0;

            for (uint i = 0; i < tradeData.ethToToken.addresses.length; i++) {
                reserve = tradeData.ethToToken.addresses[i];

                //calculate split amount without any fee
                splitAmount = (i == tradeData.ethToToken.splitValuesBps.length - 1) ? (tradeWei - amountSoFarNoFee) : tradeData.ethToToken.splitValuesBps[i] * tradeWei / BPS;
                amountSoFarNoFee += splitAmount;
                //to save gas, we make just 1 conversion rate call with splitAmount
                rate = reserve.getConversionRate(ETH_TOKEN_ADDRESS, dest, splitAmount, block.number);
                //save rate data
                tradeData.ethToToken.rates[i] = rate;
                tradeData.destAmountNoFee += calcDstQty(splitAmount, ETH_DECIMALS, tradeData.ethToToken.decimals, rate);

                //calculate split amount with just network fee
                splitAmount = (i == tradeData.ethToToken.splitValuesBps.length - 1) ? (tradeWeiMinusNetworkFee - amountSoFarWithNetworkFee) : tradeData.ethToToken.splitValuesBps[i] * tradeWeiMinusNetworkFee / BPS;
                amountSoFarWithNetworkFee += splitAmount;
                tradeData.destAmountWithNetworkFee += calcDstQty(splitAmount, ETH_DECIMALS, tradeData.ethToToken.decimals, rate);
                
                //calculate split amount with both network and custom platform fee
                splitAmount = (i == tradeData.ethToToken.splitValuesBps.length - 1) ?
                (tradeWeiMinusNetworkCustomFees - amountSoFarWithNetworkAndCustomFee)
                : tradeData.ethToToken.splitValuesBps[i] * tradeWeiMinusNetworkCustomFees / BPS;
                amountSoFarWithNetworkAndCustomFee += splitAmount;
                tradeData.actualDestAmount = calcDstQty(splitAmount, ETH_DECIMALS, tradeData.ethToToken.decimals, rate);
            }
        } else {
            // else, search best reserve and its corresponding dest amount
            // Have to search with tradeWei minus fees, because that is the actual src amount for ETH -> token trade
            require(tradeWeiMinusNetworkCustomFees >= (tradeData.tradeWei * tradeData.takerFeeBps / BPS), "ETH->token network fee exceeds remaining trade wei amt");
            (tradeData.ethToToken.addresses[0], tradeData.ethToToken.rates[0], isPayingFees) = searchBestRate(
                tradeData.ethToToken.addresses,
                ETH_TOKEN_ADDRESS,
                dest,
                tradeWeiMinusNetworkCustomFees,
                tradeData.tradeWei * tradeData.takerFeeBps / BPS
            );
            //store chosen reserve into tradeData
            tradeData.ethToToken.splitValuesBps[0] = BPS;
            tradeData.destAmountNoFee = calcDstQty(tradeWei, ETH_DECIMALS, tradeData.ethToToken.decimals, tradeData.ethToToken.rates[0]);

            // add to feePayingReservesBps if reserve is fee paying
            if (isPayingFees) {
                tradeData.networkFeeWei += tradeWei * tradeData.takerFeeBps / BPS;
                tradeData.feePayingReservesBps += BPS; //max percentage amount for ETH -> token
                tradeData.numFeePayingReserves ++;
            }

            // calculate destAmountWithNetworkFee and actualDestAmount
            // not using tradeWeiMinusNetworkFee and tradeWeiMinusNetworkCustomFee
            // since network fee might have increased for fee paying ETH -> token reserve
            tradeData.destAmountWithNetworkFee = calcDstQty(tradeWei - tradeData.networkFeeWei, ETH_DECIMALS, tradeData.ethToToken.decimals, tradeData.ethToToken.rates[0]);
            tradeData.actualDestAmount = calcDstQty(tradeWei - tradeData.networkFeeWei - tradeData.platformFeeWei, ETH_DECIMALS, tradeData.ethToToken.decimals, tradeData.ethToToken.rates[0]);
        }
    }
    
    function handleFees(TradeData memory tradeData) internal returns(bool) {
        // create array of reserves receiving fees + fee percent per reserve
        // fees should add up to 100%.
        // send total fee amount to fee handler with reserve data.
    }

    function calcTradeSrcAmounts(uint srcDecimals, uint destDecimals, uint destAmount, uint[] memory rates, 
                                uint[] memory splitValues)
        internal pure returns (uint srcAmount)
    {
        uint amountSoFar;

        for (uint i = 0; i < rates.length; i++) {
            uint destAmountSplit = i == (splitValues.length - 1) ? (destAmount - amountSoFar) : splitValues[i] * destAmount /  100;
            amountSoFar += destAmountSplit;

            srcAmount += calcSrcQty(destAmountSplit, srcDecimals, destDecimals, rates[i]);
        }
    }

    function calcTradeSrcAmountFromDest (IERC20 src, IERC20 dest, uint srcAmount, uint maxDestAmount, TradeData memory tradeData)
        internal pure returns(uint actualSrcAmount)
    {
        if (dest != ETH_TOKEN_ADDRESS) {
            tradeData.tradeWei = calcTradeSrcAmounts(tradeData.ethToToken.decimals, ETH_DECIMALS, maxDestAmount, 
                tradeData.ethToToken.rates, tradeData.ethToToken.splitValuesBps);
        } else {
            tradeData.tradeWei = maxDestAmount;
        }

        tradeData.networkFeeWei = tradeData.tradeWei * tradeData.takerFeeBps * tradeData.feePayingReservesBps / (BPS * 100) ;
        tradeData.tradeWei -= tradeData.networkFeeWei;

        if (src != ETH_TOKEN_ADDRESS) {
            actualSrcAmount = calcTradeSrcAmounts(ETH_DECIMALS, tradeData.tokenToEth.decimals, tradeData.tradeWei, tradeData.tokenToEth.rates, tradeData.tokenToEth.splitValuesBps);
        } else {
            actualSrcAmount = tradeData.tradeWei;
        }
    
        require(actualSrcAmount <= srcAmount);
    }

    event KyberTrade(address indexed trader, IERC20 src, IERC20 dest, uint srcAmount, uint dstAmount,
        address destAddress, uint ethWeiValue, address reserve1, address reserve2, bytes hint);

    /* solhint-disable function-max-lines */
    //  Most of the lines here are functions calls spread over multiple lines. We find this function readable enough
    /// @notice use token address ETH_TOKEN_ADDRESS for ether
    /// @dev trade api for kyber network.
    /// @param tradeData.input structure of trade inputs
    function trade(TradeData memory tradeData) 
        internal
        nonReentrant
        returns(uint destAmount) 
    {
        require(verifyTradeValid(tradeData.input.src, tradeData.input.srcAmount, tradeData.input.dest, tradeData.input.destAddress));

        // amounts excluding fees
        findRatesAndAmounts(tradeData.input.src, tradeData.input.dest, tradeData.input.srcAmount, tradeData);

        require(tradeData.rateWithNetworkFee > 0);
        require(tradeData.rateWithNetworkFee < MAX_RATE);
        require(tradeData.rateWithNetworkFee >= tradeData.input.minConversionRate);

        uint actualSrcAmount;

        if (tradeData.actualDestAmount > tradeData.input.maxDestAmount) {
            actualSrcAmount = calcTradeSrcAmountFromDest(
                tradeData.input.src,
                tradeData.input.dest,
                tradeData.input.srcAmount,
                tradeData.input.maxDestAmount,
                tradeData);

            require(handleChange(tradeData.input.src, tradeData.input.srcAmount, actualSrcAmount, tradeData.input.trader));
        } else {
            actualSrcAmount = tradeData.input.srcAmount;
        } 
        
        require(doReserveTrades(     //src to ETH
                tradeData.input.src,
                actualSrcAmount,
                ETH_TOKEN_ADDRESS,
                address(this),
                tradeData,
                tradeData.tradeWei));

        require(doReserveTrades(     //Eth to dest
                ETH_TOKEN_ADDRESS,
                tradeData.tradeWei,
                tradeData.input.dest,
                tradeData.input.destAddress,
                tradeData,
                tradeData.actualDestAmount));

        require(handleFees(tradeData));

        //todo: update trade event
        // KyberTrade({
        //     trader: tradeData.input.trader,
        //     src: tradeData.input.src,
        //     dest: tradeData.input.dest,
        //     srcAmount: actualSrcAmount,
        //     dstAmount: actualDestAmount,
        //     destAddress: tradeData.input.destAddress,
        //     ethWeiValue: weiAmount,
        //     reserve1: (tradeData.input.src == ETH_TOKEN_ADDRESS) ? address(0) : rateResult.reserve1,
        //     reserve2:  (tradeData.input.dest == ETH_TOKEN_ADDRESS) ? address(0) : rateResult.reserve2,
        //     hint: tradeData.input.hint
        // });

        return (tradeData.actualDestAmount);
    }
    /* solhint-enable function-max-lines */

    /// @notice use token address ETH_TOKEN_ADDRESS for ether
    /// @dev do one trade with a reserve
    /// @param src Src token
    /// @param amount amount of src tokens
    /// @param dest   Destination token
    /// @param destAddress Address to send tokens to
    /// @return true if trade is successful
    function doReserveTrades(
        IERC20 src,
        uint amount,
        IERC20 dest,
        address payable destAddress,
        TradeData memory tradeData,
        uint expectedDestAmount
    )
        internal
        returns(bool)
    {
        if (src == dest) {
            //this is for a "fake" trade when both src and dest are ethers.
            if (destAddress != (address(this)))
                destAddress.transfer(amount);
            return true;
        }

        TradingReserves memory reservesData = src == ETH_TOKEN_ADDRESS? tradeData.ethToToken : tradeData.tokenToEth;
        uint callValue;
        uint amountSoFar;

        for(uint i = 0; i < reservesData.addresses.length; i++) {
            uint splitAmount = i == (reservesData.splitValuesBps.length - 1) ? (amount - amountSoFar) : reservesData.splitValuesBps[i] * amount /  100;
            amountSoFar += splitAmount;
            callValue = (src == ETH_TOKEN_ADDRESS)? splitAmount : 0;

            // reserve sends tokens/eth to network. network sends it to destination
            // todo: if reserve supports returning destTokens call accordingly
            require(reservesData.addresses[i].trade.value(callValue)(src, splitAmount, dest, address(this), reservesData.rates[i], true));
        }

        if (destAddress != address(this)) {
            //for token to token dest address is network. and Ether / token already here...
            if (dest == ETH_TOKEN_ADDRESS) {
                destAddress.transfer(expectedDestAmount);
            } else {
                require(dest.transfer(destAddress, expectedDestAmount));
            }
        }

        return true;
    }

    /// when user sets max dest amount we could have too many source tokens == change. so we send it back to user.
    function handleChange (IERC20 src, uint srcAmount, uint requiredSrcAmount, address payable trader) internal returns (bool) {

        if (requiredSrcAmount < srcAmount) {
            //if there is "change" send back to trader
            if (src == ETH_TOKEN_ADDRESS) {
                trader.transfer(srcAmount - requiredSrcAmount);
            } else {
                require(src.transfer(trader, (srcAmount - requiredSrcAmount)));
            }
        }

        return true;
    }

    /// @notice use token address ETH_TOKEN_ADDRESS for ether
    /// @dev checks that user sent ether/tokens to contract before trade
    /// @param src Src token
    /// @param srcAmount amount of src tokens
    /// @return true if tradeInput is valid
    function verifyTradeValid(IERC20 src, uint srcAmount, IERC20 dest, address destAddress)
        internal
        view
        returns(bool)
    {
        require(isEnabled);
        require(msg.sender == kyberNetworkProxyContract);
        require(tx.gasprice <= maxGasPriceValue);
        require(srcAmount <= MAX_QTY);
        require(srcAmount != 0);
        require(destAddress != address(0));
        require(src != dest);

        if (src == ETH_TOKEN_ADDRESS) {
            require(msg.value == srcAmount);
        } else {
            require(msg.value == 0);
            //funds should have been moved to this contract already.
            require(src.balanceOf(address(this)) >= srcAmount);
        }

        return true;
    }
    
    // get fee view function. for get expected rate
    function getTakerFee() internal view returns(uint takerFeeBps) {
        return 25;

        // todo: read data. decode. read from DAO if expired;
        // todo: don't revert if DAO reverts. just return exsiting value.
    }
    
    // get fee function for trade. get fee and update data if expired.
    function getAndUpdateTakerFee() internal returns(uint takerFeeBps) {
        return 25;

        // todo: read data. decode. 
        // todo: if expired read from DAO and encode
        // todo: don't revert if DAO reverts. just return exsiting value.
        // handle situation where DAO doesn't exist
    }
    
    function decodeTakerFee(uint feeData) internal pure returns(uint expiryBlock, uint takerFeeDataDecoded) {
        
    }
    
    function encodeTakerFee(uint expiryBlock, uint feeBps) internal pure returns(uint feeData) {
        
    }
    
    function parseTradeDataHint(TradeData memory tradeData,  bytes memory hint) internal view {
        tradeData.tokenToEth.addresses = reservesPerTokenSrc[address(tradeData.input.src)];
        tradeData.ethToToken.addresses = reservesPerTokenDest[address(tradeData.input.dest)];
        //PERM_HINT is treated as no hint, so we just return
        if (hint.length == 0 || keccak256(hint) == keccak256(PERM_HINT)) return;
    }
}