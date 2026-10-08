// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    KeyfleetDeployer,
    KeyfleetManagerDeployer,
    KeyfleetRewardsDeployer,
    KeyfleetTreasuryDeployer,
    KeyfleetVotesDeployer
} from "../src/KeyfleetDeployers.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {IKeyfleetFactory} from "../src/KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";

/// @notice Deploys the Keyfleet system: the four deployers, then the factory, whose constructor
/// deploys the collection, the shard record, the REGENT buyer and the Regents Club claims.
/// @dev Each deployer is given the factory's address before the factory exists: the deploying
/// account's fifth contract address from now. The factory refuses a deployer that names any other
/// address, so a wrong prediction reverts the deployment. The deploying account is the broadcasting
/// account inside a broadcast, and the calling contract otherwise. The deployment script, the anvil
/// lab and the suite all deploy through here.
library KeyfleetSystem {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Everything the factory is deployed with except its four deployers.
    struct Bindings {
        address safe;
        address keeper;
        IRegentRevenueStaking staking;
        IRegentsAutolaunchFactoryV2 autolaunch;
        IERC721 clubPass;
        KeyfleetKeys.Collection collection;
        KeyfleetKeys.Randomness randomness;
        bytes32 traitTableHash;
        KeyfleetRegentBuyer.Route route;
    }

    /// @notice Deploys the four deployers and the factory.
    function deploy(Bindings memory bindings) internal returns (KeyfleetFactory factory) {
        address deployer = _deployer();
        IKeyfleetFactory predicted = IKeyfleetFactory(VM.computeCreateAddress(deployer, VM.getNonce(deployer) + 4));
        KeyfleetDeployer managerDeployer = new KeyfleetManagerDeployer(predicted);
        KeyfleetDeployer votesDeployer = new KeyfleetVotesDeployer(predicted);
        KeyfleetDeployer treasuryDeployer = new KeyfleetTreasuryDeployer(predicted);
        KeyfleetDeployer rewardsDeployer = new KeyfleetRewardsDeployer(predicted);
        factory = new KeyfleetFactory(
            KeyfleetFactory.Config({
                safe: bindings.safe,
                keeper: bindings.keeper,
                staking: bindings.staking,
                autolaunch: bindings.autolaunch,
                clubPass: bindings.clubPass,
                collection: bindings.collection,
                randomness: bindings.randomness,
                traitTableHash: bindings.traitTableHash,
                route: bindings.route,
                managerDeployer: managerDeployer,
                votesDeployer: votesDeployer,
                treasuryDeployer: treasuryDeployer,
                rewardsDeployer: rewardsDeployer
            })
        );
    }

    function _deployer() private returns (address) {
        (VmSafe.CallerMode mode, address sender,) = VM.readCallers();
        if (mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast) return sender;
        return address(this);
    }
}
