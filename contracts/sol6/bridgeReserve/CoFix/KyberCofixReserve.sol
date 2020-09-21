pragma solidity 0.6.6;

import "../../IKyberReserve.sol";
import "../../IERC20.sol";
import "../../utils/Withdrawable3.sol";
import "../../utils/Utils5.sol";
import "../../utils/zeppelin/SafeERC20.sol";
import "./mock/ICoFiXRouter.sol";
import "./mock/ICoFiXFactory.sol";
import "./mock/INest_3_OfferPrice.sol";

contract KyberCofixReserve is IKyberReserve, Withdrawable3, Utils5 {
    using SafeERC20 for IERC20;

    ICoFiXRouter iCoFiXRouter;
    ICoFiXFactory iCoFixFactory;
    INest_3_OfferPrice iNest_3_OfferPrice;
    address NESTOracle = 0x7722891Ee45aD38AE05bDA8349bA4CF23cFd270F;
    address cofixFactory = 0xd5a19e1adb5592921dcc42e48623d75c4c91e405;
    uint256 internal constant COFIX_ORACLE_FEE = 0.01 ether; // only for CoFiX
    address public kyberNetwork;

    constructor(
        ICoFiXRouter _iCoFiXRouter,
        address _weth,
        address _admin,
        address _kyberNetwork
    ) public Withdrawable3(_admin) {
        require(address(_iCoFiXRouter) != address(0), "_iCoFiXRouter 0");
        require(_weth != address(0), "weth 0");
        require(_kyberNetwork != address(0), "kyberNetwork 0");

        iCoFiXRouter = _iCoFiXRouter;
        iCoFixFactory = iCoFixFactory(cofixFactory);
        iNest_3_OfferPrice = INest_3_OfferPrice(NESTOracle);
        weth = _weth;
        kyberNetwork = _kyberNetwork;
    }

    //TODO complete
    function trade(
        IERC20 srcToken,
        uint256 srcAmount,
        IERC20 destToken,
        address payable destAddress,
        uint256 conversionRate,
        bool validate
    ) public payable returns (bool) {
        require(msg.sender == kyberNetwork, "only kyberNetwork");
        require(isValidTokens(srcToken, destToken), "only use eth and listed token");
        if (srcToken == ETH_TOKEN_ADDRESS) {
            require(msg.value == srcAmount + COFIX_ORACLE_FEE, "msg.value != srcAmount + COFIX_ORACLE_FEE");
        } else {
            require(msg.value == COFIX_ORACLE_FEE * 2, "swap twice, pay twice: token A -> ETH, then ETH ->  token B");
        }
        (uint256 ethAmountSrc, uint256 erc20AmountSrc) = iNest_3_OfferPrice.checkPriceForBlock(address(src), blockNumber);
        uint amountMinEth = (srcAmount / erc20AmountSrc) * ethAmountSrc;
        iCoFiXRouter.swapExactTokensForTokens(
            srcToken,
            destToken,
            srcAmount,
            amountMinEth,
            destAddress,
            block.now + 100000 //TODO how should the deadline be set?
        );
        return true;
    }

    //TODO complete
    function getConversionRate(
        IERC20 src,
        IERC20 dest,
        uint256 srcQty,
        uint256 blockNumber
    ) public view returns (uint256) {
        (uint256 ethAmountSrc, uint256 erc20AmountSrc) = iNest_3_OfferPrice.checkPriceForBlock(address(src), blockNumber);
        (uint256 ethAmountDest, uint256 erc20AmountDest) = iNest_3_OfferPrice.checkPriceForBlock(address(dest), blockNumber);
        return srcQty * (ethAmountSrc / ethAmountDest);
    }


}
