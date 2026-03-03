// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {Mobius, ISwapHelper} from "../src/Mobius.sol";

contract MockSwapHelper is ISwapHelper {
    address internal immutable _usdt;
    address internal immutable _wbnb;
    address internal immutable _rewardToken;
    uint256 internal immutable _bnbPriceInUsdt;
    uint256 internal immutable _rewardPriceInUsdt;

    constructor(
        address usdt_,
        address wbnb_,
        address rewardToken_,
        uint256 bnbPriceInUsdt_,
        uint256 rewardPriceInUsdt_
    ) {
        _usdt = usdt_;
        _wbnb = wbnb_;
        _rewardToken = rewardToken_;
        _bnbPriceInUsdt = bnbPriceInUsdt_;
        _rewardPriceInUsdt = rewardPriceInUsdt_;
    }

    function usdt() external view returns (address) {
        return _usdt;
    }

    function wbnb() external view returns (address) {
        return _wbnb;
    }

    function getBNBPriceInUSDT() external view returns (uint256) {
        return _bnbPriceInUsdt;
    }

    function quoteTokenPriceInUSDT(address) external view returns (uint256) {
        return _rewardPriceInUsdt;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }
}
contract MockERC20 {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
contract MockMintableToken is MockERC20 {
    function mint(address, uint256) external pure returns (bool) {
        return true;
    }
}
contract MobiusHarness is Mobius {
    constructor(address owner_, address caller_, address helper_) Mobius(owner_, caller_, helper_) {}

    function quoteReserveValueForTest(address token, uint256 amount) external view returns (uint256) {
        return _quoteReserveValue(token, amount);
    }

    function quoteMintAmountForTest(address token, uint256 reserveValue) external view returns (uint256) {
        return _quoteMintAmount(token, reserveValue);
    }
}

contract MobiusHalmosTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant BNB_PRICE_IN_USDT = 650;
    uint256 internal constant MBU_PRICE_IN_USDT = 67;

    MobiusHarness internal mobius;
    address internal wbnb;

    function setUp() public {
        address rewardToken = address(new MockMintableToken());
        address usdt = address(new MockERC20());
        wbnb = address(new MockERC20());

        MockSwapHelper helper = new MockSwapHelper(usdt, wbnb, rewardToken, BNB_PRICE_IN_USDT, MBU_PRICE_IN_USDT);

        mobius = new MobiusHarness(address(this), address(this), address(helper));
    }

    function check_Mint(uint256 wantAmt) public view {

        uint256 reserveValue = mobius.quoteReserveValueForTest(wbnb, wantAmt);
        uint256 expectedMint = reserveValue / MBU_PRICE_IN_USDT;
        vm.assume(expectedMint > 0);

        uint256 buggyMint = mobius.quoteMintAmountForTest(wbnb, reserveValue);

        assertEq(buggyMint, expectedMint);
    }
}
