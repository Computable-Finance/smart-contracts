pragma solidity 0.6.0;

interface INest_3_OfferPrice {
    // Check block price - user account only
    function checkPriceForBlock(address tokenAddress, uint256 blockNum) external view returns (uint256 ethAmount, uint256 erc20Amount);
}