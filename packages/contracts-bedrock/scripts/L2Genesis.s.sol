// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

import { Artifacts } from "scripts/Artifacts.s.sol";
import { DeployConfig, DEV_ACCOUNT_FUND_AMT } from "scripts/DeployConfig.s.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";
import { L1StandardBridge } from "src/L1/L1StandardBridge.sol";
import { L1CrossDomainMessenger } from "src/L1/L1CrossDomainMessenger.sol";
import { L2StandardBridge } from "src/L2/L2StandardBridge.sol";
import { L2CrossDomainMessenger } from "src/L2/L2CrossDomainMessenger.sol";
import { SequencerFeeVault } from "src/L2/SequencerFeeVault.sol";
import { FeeVault } from "src/universal/FeeVault.sol";
import { OptimismMintableERC20Factory } from "src/universal/OptimismMintableERC20Factory.sol";
import { L1Block } from "src/L2/L1Block.sol";
import { GovernanceToken } from "src/governance/GovernanceToken.sol";
import { EIP1967Helper } from "test/mocks/EIP1967Helper.sol";
import { L2GenesisHelpers } from "scripts/libraries/L2GenesisHelpers.sol";

interface IInitializable {
    function initialize(address _addr) external;
}

/// @dev The general flow of adding a predeploy is:
///      1. _setPredeployProxies uses vm.etch to set the Proxy.sol deployed bytecode for proxy address `0x420...000` to
/// `0x420...000 + PROXY_COUNT - 1`.
///      Additionally, the PROXY_ADMIN_ADDRESS and PROXY_IMPLEMENTATION_ADDRESS storage slots are set for the proxy
///      address.
///      2. `vm.etch` sets the deployed bytecode for each predeploy at the implementation address (i.e. `0xc0d3`
/// namespace).
///      3. The `initialize` method is called at the implementation address with zero/dummy vaules if the method exists.
///      4. The `initialize` method is called at the proxy address with actual vaules if the method exists.
///      5. A `require` check to verify the expected implementation address is set for the proxy.
/// @notice The following safety invariants are used when setting state:
///         1. `vm.getDeployedBytecode` can only be used with `vm.etch` when there are no side
///         effects in the constructor and no immutables in the bytecode.
///         2. A contract must be deployed using the `new` syntax if there are immutables in the code.
///         Any other side effects from the init code besides setting the immutables must be cleaned up afterwards.
///         3. A contract is deployed using the `new` syntax, however it's not proxied and is still expected to exist at
/// a
///         specific implementation address (i.e. `0xc0d3` namespace). In this case we deploy an instance of the
/// contract
///         using `new` syntax, use `contract.code` to retrieve it's deployed bytecode, `vm.etch` the bytecode at the
///         expected implementation address, and `vm.store` to set any storage slots that are
///         expected to be set after a new deployment. Lastly, we reset the account code and storage slots the contract
///         was initially deployed to so it's not included in the `vm.dumpState`.
contract L2Genesis is Script, Artifacts {
    DeployConfig public constant cfg =
        DeployConfig(address(uint160(uint256(keccak256(abi.encode("optimism.deployconfig"))))));

    string internal outfile;

    /// @dev Reads the deploy config, sets `outfile` which is where the `vm.dumpState` will be saved to, and
    ///      loads in the addresses for the L1 contract deployments.
    function setUp() public override {
        Artifacts.setUp();

        string memory path = string.concat(vm.projectRoot(), "/deploy-config/", deploymentContext, ".json");
        vm.etch(address(cfg), vm.getDeployedCode("DeployConfig.s.sol:DeployConfig"));
        vm.label(address(cfg), "DeployConfig");
        vm.allowCheatcodes(address(cfg));
        cfg.read(path);

        outfile = string.concat(vm.projectRoot(), "/deployments/", deploymentContext, "/genesis-l2.json");

        _loadAddresses(string.concat(vm.projectRoot(), "/deployments/", deploymentContext, "/.deploy"));
    }

    /// @dev Sets the precompiles, proxies, and the implementation accounts to be `vm.dumpState`
    ///      to generate a L2 genesis alloc.
    /// @notice The alloc object is sorted numerically by address.
    function run() public {
        _dealEthToPrecompiles();
        _setPredeployProxies();
        _setPredeployImplementations();

        if (cfg.fundDevAccounts()) {
            _fundDevAccounts();
        }

        /// Reset so its not included state dump
        vm.etch(address(cfg), "");

        vm.dumpState(outfile);
        _sortJsonByKeys(outfile);
    }

    /// @notice Give all of the precompiles 1 wei so that they are
    ///         not considered empty accounts.
    function _dealEthToPrecompiles() internal {
        for (uint256 i; i < L2GenesisHelpers.PRECOMPILE_COUNT; i++) {
            vm.deal(address(uint160(i)), 1);
        }
    }

    /// @dev Set up the accounts that correspond to the predeploys.
    ///      The Proxy bytecode should be set. All proxied predeploys should have
    ///      the 1967 admin slot set to the ProxyAdmin predeploy. All defined predeploys
    ///      should have their implementations set.
    function _setPredeployProxies() internal {
        bytes memory code = vm.getDeployedCode("Proxy.sol:Proxy");
        uint160 prefix = uint160(0x420) << 148;

        console.log(
            "Setting proxy deployed bytecode for addresses in range %s through %s",
            address(prefix | uint160(0)),
            address(prefix | uint160(L2GenesisHelpers.PROXY_COUNT - 1))
        );
        for (uint256 i = 0; i < L2GenesisHelpers.PROXY_COUNT; i++) {
            address addr = address(prefix | uint160(i));
            if (L2GenesisHelpers.notProxied(addr)) {
                continue;
            }

            vm.etch(addr, code);
            vm.store(addr, EIP1967Helper.PROXY_OWNER_ADDRESS, bytes32(uint256(uint160(Predeploys.PROXY_ADMIN))));

            if (L2GenesisHelpers.isDefinedPredeploy(addr)) {
                address implementation = L2GenesisHelpers.predeployToCodeNamespace(addr);
                console.log("Setting proxy %s implementation: %s", addr, implementation);
                vm.store(addr, EIP1967Helper.PROXY_IMPLEMENTATION_ADDRESS, bytes32(uint256(uint160(implementation))));
            }
        }
    }

    /// @notice LEGACY_ERC20_ETH is not being predeployed since it's been deprecated.
    /// @dev Sets all the implementations for the predeploy proxies. For contracts without proxies,
    ///      sets the deployed bytecode at their expected predeploy address.
    function _setPredeployImplementations() internal {
        _setLegacyMessagePasser();
        _setDeployerWhitelist();
        _setWETH9();
        _setL2StandardBridge();
        _setL2CrossDomainMessenger();
        _setSequencerFeeVault();
        _setOptimismMintableERC20Factory();
        _setL1BlockNumber();
        _setGasPriceOracle();
        _setGovernanceToken();
        _setL1Block();
    }

    /// @notice This predeploy is following the saftey invariant #1.
    function _setLegacyMessagePasser() internal {
        _setImplementationCode(Predeploys.LEGACY_MESSAGE_PASSER, "LegacyMessagePasser");
    }

    /// @notice This predeploy is following the saftey invariant #1.
    function _setDeployerWhitelist() internal {
        _setImplementationCode(Predeploys.DEPLOYER_WHITELIST, "DeployerWhitelist");
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         Contract metadata hash appended to deployed bytecode will differ
    ///         from previous L2 genesis output.
    ///         This contract is NOT proxied.
    /// @dev We're manually setting storage slots because we need to deployment to be at
    ///      the address `Predeploys.WETH9`, so we can't just deploy a new instance of `WETH9`.
    function _setWETH9() internal {
        console.log("Setting %s implementation at: %s", "WETH9", Predeploys.WETH9);
        vm.etch(Predeploys.WETH9, vm.getDeployedCode("WETH9.sol:WETH9"));

        vm.store(
            Predeploys.WETH9,
            /// string public name
            hex"0000000000000000000000000000000000000000000000000000000000000000",
            /// "Wrapped Ether"
            hex"577261707065642045746865720000000000000000000000000000000000001a"
        );
        vm.store(
            Predeploys.WETH9,
            /// string public symbol
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            /// "WETH"
            hex"5745544800000000000000000000000000000000000000000000000000000008"
        );
        vm.store(
            Predeploys.WETH9,
            // uint8 public decimals
            hex"0000000000000000000000000000000000000000000000000000000000000002",
            /// 18
            hex"0000000000000000000000000000000000000000000000000000000000000012"
        );
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         We're initializing the implementation with `address(0)` so
    ///         it's not left uninitialized. After `initialize` is called on the
    ///         proxy to set the storage slot with the expected value.
    function _setL2StandardBridge() internal {
        address impl = _setImplementationCode(Predeploys.L2_STANDARD_BRIDGE, "L2StandardBridge");

        L2StandardBridge(payable(impl)).initialize(L1StandardBridge(payable(address(0))));

        L2StandardBridge(payable(Predeploys.L2_STANDARD_BRIDGE)).initialize(
            L1StandardBridge(mustGetAddress("L1StandardBridgeProxy"))
        );

        _checkL2StandardBridge(impl);
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         We're initializing the implementation with `address(0)` so
    ///         it's not left uninitialized. After `initialize` is called on the
    ///         proxy to set the storage slot with the expected value.
    function _setL2CrossDomainMessenger() internal {
        address impl = _setImplementationCode(Predeploys.L2_CROSS_DOMAIN_MESSENGER, "L2CrossDomainMessenger");

        L2CrossDomainMessenger(impl).initialize(L1CrossDomainMessenger(address(0)));

        L2CrossDomainMessenger(Predeploys.L2_CROSS_DOMAIN_MESSENGER).initialize(
            L1CrossDomainMessenger(mustGetAddress("L1CrossDomainMessengerProxy"))
        );

        _checkL2CrossDomainMessenger(impl);
    }

    /// @notice This predeploy is following the saftey invariant #2,
    ///         because the constructor args are non-static L1 contract
    ///         addresses that are being read from the deploy config
    ///         that are set as immutables.
    /// @dev Because the constructor args are stored as immutables,
    ///      we don't have to worry about setting storage slots.
    function _setSequencerFeeVault() internal {
        SequencerFeeVault vault = new SequencerFeeVault({
            _recipient: cfg.sequencerFeeVaultRecipient(),
            _minWithdrawalAmount: cfg.sequencerFeeVaultMinimumWithdrawalAmount(),
            _withdrawalNetwork: FeeVault.WithdrawalNetwork(cfg.sequencerFeeVaultWithdrawalNetwork())
        });

        address impl = L2GenesisHelpers.predeployToCodeNamespace(Predeploys.SEQUENCER_FEE_WALLET);
        console.log("Setting %s implementation at: %s", "SequencerFeeVault", impl);
        vm.etch(impl, address(vault).code);

        /// Reset so its not included state dump
        vm.etch(address(vault), "");
        vm.resetNonce(address(vault));

        _checkSequencerFeeVault(impl);
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         We're initializing the implementation with `address(0)` so
    ///         it's not left uninitialized. After `initialize` is called on the
    ///         proxy to set the storage slot with the expected value.
    function _setOptimismMintableERC20Factory() internal {
        address impl =
            _setImplementationCode(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY, "OptimismMintableERC20Factory");

        OptimismMintableERC20Factory(impl).initialize(address(0));

        OptimismMintableERC20Factory(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY).initialize(
            Predeploys.L2_STANDARD_BRIDGE
        );

        _checkOptimismMintableERC20Factory(impl);
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         This contract has no initializer.
    function _setL1BlockNumber() internal {
        _setImplementationCode(Predeploys.L1_BLOCK_NUMBER, "L1BlockNumber");
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         This contract has no initializer.
    function _setGasPriceOracle() internal {
        _setImplementationCode(Predeploys.GAS_PRICE_ORACLE, "GasPriceOracle");
    }

    /// @notice This predeploy is following the saftey invariant #3.
    function _setGovernanceToken() internal {
        if (!cfg.enableGovernance()) {
            console.log("Governance not enabled, skipping setting governanace token");
            return;
        }

        GovernanceToken token = new GovernanceToken();
        console.log("Setting %s implementation at: %s", "GovernanceToken", Predeploys.GOVERNANCE_TOKEN);
        vm.etch(Predeploys.GOVERNANCE_TOKEN, address(token).code);

        bytes32 _nameSlot = hex"0000000000000000000000000000000000000000000000000000000000000003";
        bytes32 _symbolSlot = hex"0000000000000000000000000000000000000000000000000000000000000004";
        bytes32 _ownerSlot = hex"000000000000000000000000000000000000000000000000000000000000000a";

        vm.store(Predeploys.GOVERNANCE_TOKEN, _nameSlot, vm.load(address(token), _nameSlot));
        vm.store(Predeploys.GOVERNANCE_TOKEN, _symbolSlot, vm.load(address(token), _symbolSlot));
        vm.store(Predeploys.GOVERNANCE_TOKEN, _ownerSlot, bytes32(uint256(uint160(cfg.governanceTokenOwner()))));

        /// Reset so its not included state dump
        vm.etch(address(token), "");
        vm.resetNonce(address(token));
    }

    /// @notice This predeploy is following the saftey invariant #1.
    ///         This contract has no initializer.
    /// @dev Previously the initial L1 attributes was set at genesis, to simplify,
    ///      they no longer are so the resulting storage slots are no longer set.
    function _setL1Block() internal {
        _setImplementationCode(Predeploys.L1_BLOCK_ATTRIBUTES, "L1Block");
    }

    function _setImplementationCode(address _addr, string memory _name) internal returns (address) {
        address impl = L2GenesisHelpers.predeployToCodeNamespace(_addr);
        console.log("Setting %s implementation at: %s", _name, impl);
        vm.etch(impl, vm.getDeployedCode(string.concat(_name, ".sol:", _name)));

        _verifyProxyImplementationAddress(_addr, impl);

        return impl;
    }

    /// @dev Function to verify the expected implementation address is set for the respective proxy.
    function _verifyProxyImplementationAddress(address _proxy, address _impl) internal view {
        require(
            EIP1967Helper.getImplementation(_proxy) == _impl,
            "Expected different address at Proxys PROXY_IMPLEMENTATION_ADDRESS storage slot"
        );
    }

    /// @dev Function to verify that a contract was initialized, and can't be reinitialized.
    /// @notice There isn't a good way to know if the resulting revering is due to abi mismatch
    ///         or because it's already been initialized
    function _verifyCantReinitialize(address _contract, address _arg) internal {
        vm.expectRevert("Initializable: contract is already initialized");
        IInitializable(_contract).initialize(_arg);
    }

    /// @dev Helper function to sort the genesis alloc numerically by address.
    /// @notice The storage slot keys are also sorted numerically.
    function _sortJsonByKeys(string memory _path) internal {
        string[] memory commands = new string[](3);
        commands[0] = "bash";
        commands[1] = "-c";
        commands[2] = string.concat(
            "cat <<< $(jq -S '",
            "to_entries | ",
            "map( {key: .key, value: {balance: .value.balance, code: .value.code, nonce: .value.nonce, storage: (.value.storage | to_entries | sort_by(.key) | from_entries)} } ) | ",
            "from_entries' ",
            _path,
            ") > ",
            _path
        );
        vm.ffi(commands);
    }

    function _fundDevAccounts() internal {
        for (uint256 i; i < cfg.getDevAccounts().length; i++) {
            console.log("Funding dev account %s with %s ETH", cfg.getDevAccounts()[i], DEV_ACCOUNT_FUND_AMT / 1e18);
            vm.deal(cfg.getDevAccounts()[i], DEV_ACCOUNT_FUND_AMT);
        }

        _checkDevAccountsFunded();
    }

    //////////////////////////////////////////////////////
    /// Post Checks
    //////////////////////////////////////////////////////
    function _checkL2StandardBridge(address _impl) internal {
        _verifyCantReinitialize(_impl, address(0));
        _verifyCantReinitialize(Predeploys.L2_STANDARD_BRIDGE, mustGetAddress("L1StandardBridgeProxy"));
    }

    function _checkL2CrossDomainMessenger(address _impl) internal {
        _verifyCantReinitialize(_impl, address(0));
        _verifyCantReinitialize(Predeploys.L2_CROSS_DOMAIN_MESSENGER, mustGetAddress("L1CrossDomainMessengerProxy"));
    }

    function _checkSequencerFeeVault(address _impl) internal view {
        _verifyProxyImplementationAddress(Predeploys.SEQUENCER_FEE_WALLET, _impl);
    }

    function _checkOptimismMintableERC20Factory(address _impl) internal {
        _verifyCantReinitialize(_impl, address(0));
        _verifyCantReinitialize(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY, Predeploys.L2_STANDARD_BRIDGE);
    }

    function _checkDevAccountsFunded() internal view {
        for (uint256 i; i < cfg.getDevAccounts().length; i++) {
            if (cfg.getDevAccounts()[i].balance != DEV_ACCOUNT_FUND_AMT) {
                revert(
                    string.concat(
                        "Dev account not funded with expected amount of ETH: ", vm.toString(cfg.getDevAccounts()[i])
                    )
                );
            }
        }
    }
}
