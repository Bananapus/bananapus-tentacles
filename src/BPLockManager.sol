// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IBPTentacle} from "./interfaces/IBPTentacle.sol";
import {IBPTentacleHelper} from "./interfaces/IBPTentacleHelper.sol";
import {IBPLockManager} from "./interfaces/IBPLockManager.sol";
import {IStakingDelegate} from "./interfaces/IStakingDelegate.sol";

enum TENTACLE_STATE {
    NONE,
    CREATED
}

struct TentacleCreateData {
    uint8 id;
    IBPTentacleHelper helper;
}

struct TentacleConfiguration {
    // Defines if a default helper is set (saves us an sload to check)
    bool hasDefaultHelper;
    // Should overrides be disabled
    bool forceDefault;
    // If a forced default is set and the user provides an override,
    // should this cause a revert, or should we not revert and use the forced default
    bool revertIfDefaultForcedAndOverriden;
    // ... room for some flags
    IBPTentacle tentacle;
}

contract BPLockManager is IBPLockManager {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//
    error ONLY_DELEGATE();
    error INVALID_DELEGATE();
    error NOT_SET_AS_LOCKMANAGER(uint256 _tokenId);
    error NOT_ALLOWED(uint256 _tokenId);
    error ALREADY_CREATED(uint8 _tentacleID, uint256 _tokenId);
    error TENTACLE_NOT_SET(uint8 _tentacleID);
    error TENTACLE_HAS_DEFAULT_HELPER(uint8 _tentacleID);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /**
     * @dev
     * The delegate that this lockManager is for.
     */
    IStakingDelegate immutable stakingDelegate;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /**
     * @dev
     * The outstanding tentacles for each token. The index of the activated bits identify which tentacles are outstanding.
     * ex. `0x5` means that both tentacleId 0 and 2 are outstanding
     */
    mapping(uint256 _tokenID => bytes32) outstandingTentacles;

    /**
     * @dev
     * Limited to be a `uint8` since this is the limit of the `outstandingTentacles` bitmap.
     */
    mapping(uint8 => TentacleConfiguration) public tentacles;

    mapping(uint8 => IBPTentacleHelper) public defaultTentacleHelper;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    function isUnlocked(address _token, uint256 _id) external view override returns (bool) {
        // Safety precaution to make sure if another delegate accidentally has this as its lockManager it will not lock any tokens indefinetly
        if (_token != address(stakingDelegate)) return true;
        // Check if no bits are set, if none are then this token is unlocked
        return uint256(outstandingTentacles[_id]) == 0;
    }

    function tenacleCreated(uint256 _tokenID, uint8 _tentacleID) external view returns (bool) {
        return _getTentacle(outstandingTentacles[_tokenID], _tentacleID) == TENTACLE_STATE.CREATED;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor(IStakingDelegate _stakingDelegate) {
        stakingDelegate = _stakingDelegate;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /**
     * @notice hook that (optionally) gets called upon registration as a lockManager.
     * @param _payer the person who send the transaction and paid for the staked position
     * @param _beneficiary the person who received the staked position
     * @param _tokenIDs The tokenID that got registered.
     * @param _data data regarding the lock as send by the user
     */
    function onRegistration(
        address _payer,
        address _beneficiary,
        uint256 _stakingAmount,
        uint256[] memory _tokenIDs,
        bytes calldata _data
    ) external override {
        // NOTICE: The user provides this data we have to make sure we protect against specifying the same tentacle multiple times
        _payer;
        _stakingAmount;

        // Make sure only the delegate can call this
        if (msg.sender != address(stakingDelegate)) revert ONLY_DELEGATE();
        
        (TentacleCreateData[] memory _tentacleData) = abi.decode(_data, (TentacleCreateData[]));
        uint256 _tokenCount = _tokenIDs.length;

        // Verify that these all these tokens can be registered for the tentacles and register them 
        uint256 _totalTokenCount;
        for(uint256 _i; _i < _tokenCount;) {
            _registerTentacles(_tokenIDs[_i], _tentacleData);
            _totalTokenCount += stakingDelegate.stakingTokenBalance(_tokenIDs[_i]);
            unchecked {
                ++_i;
            }
        }

        // For each tentacle we mint all the positions at once
        uint256 _nTentacles = _tentacleData.length;
        for (uint256 _i; _i < _nTentacles;) {
            _create(_tentacleData[_i].id, _tokenIDs, _beneficiary, _totalTokenCount, _tentacleData[_i].helper);
            unchecked {
                ++_i;
            }
        }

        // TODO: emit event?
    }

    /**
     * @notice hook called upon redemption
     * @param _tokenID the id of the token being redeemed
     * @param _owner the current owner of the token
     */
    function onRedeem(uint256 _tokenID, address _owner) external override {
        _tokenID;
        // Make sure only the delegate can call this
        if (msg.sender != address(stakingDelegate)) revert ONLY_DELEGATE();
        bytes32 _outstandingTentacles = outstandingTentacles[_tokenID];

        // Perform a quick check to see if any are set, if none are set we can do a quick return
        if (uint256(_outstandingTentacles) == 0) return;

        for (uint256 _i; _i < 256;) {
            // Check if the tentacle has been created, if it has attempt to destroy it
            if (_getTentacle(_outstandingTentacles, uint8(_i)) == TENTACLE_STATE.CREATED) {
                _destroy(uint8(_i), _tokenID, _owner, _owner);
            }

            unchecked {
                ++_i;
            }
        }
    }

    function create(uint8 _tentacleID, uint256 _tokenID, address _beneficiary, IBPTentacleHelper _helperOverride)
        external
    {
        // Make sure that this lockManager is in control of locking the token
        if (stakingDelegate.lockManager(_tokenID) != address(this)) revert NOT_SET_AS_LOCKMANAGER(_tokenID);
        // Check that the sender has permission to create tentacles for the token
        if (!stakingDelegate.isApprovedOrOwner(msg.sender, _tokenID)) revert NOT_ALLOWED(_tokenID);

        // Get the value of the token
        uint256 _amount = stakingDelegate.stakingTokenBalance(_tokenID);
        uint256[] memory _tokenIds = new uint256[](1);
        _tokenIds[0] = _tokenID;

        // Check if the tentacle can be registered and set it as registered
        _registerTentacle(_tentacleID, _tokenID);
        // Create the position
        _create(_tentacleID, _tokenIds, _beneficiary, _amount, _helperOverride);

        // TODO: emit event?
    }

    function destroy(uint8 _tentacleID, uint256 _tokenID) external {
        // Check that the sender has permission to destroy tentacles for the token
        if (!stakingDelegate.isApprovedOrOwner(msg.sender, _tokenID)) revert NOT_ALLOWED(_tokenID);

        _destroy(_tentacleID, _tokenID, msg.sender, msg.sender);

        // TODO: emit event?
    }

    function setTentacle(
        uint8 _tentacleID,
        TentacleConfiguration calldata _configuration,
        IBPTentacleHelper _defaultHelper
    ) external {
        // NOTICE
        // TODO: Add owner check!

        // Should we allow a tentacle to be replaced?
        tentacles[_tentacleID] = _configuration;
        defaultTentacleHelper[_tentacleID] = _defaultHelper;

        // TODO: emit event
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    function _registerTentacles(
        uint256 _tokenID,
        TentacleCreateData[] memory _tentacles
    ) internal {
        bytes32 _outstandingTentacles = outstandingTentacles[_tokenID];

        for (uint256 _i; _i < _tentacles.length;) {
            // Check if this tentacle has already been registered
            if (_getTentacle(_outstandingTentacles, _tentacles[_i].id) == TENTACLE_STATE.CREATED) {
                revert ALREADY_CREATED(_tentacles[_i].id, _tokenID);
            }

            // Register it
            _outstandingTentacles = _setTentacle(_outstandingTentacles, _tentacles[_i].id);

            unchecked {
                ++_i;
            }
        }

        // Update all the newly registered tentacles at once
        outstandingTentacles[_tokenID] = _outstandingTentacles;
    }


    function _registerTentacle(
        uint8 _tentacleID,
        uint256 _tokenID
    ) internal {
         // Check that the tentacle hasn't been created yet for this token
        bytes32 _outstandingTentacles = outstandingTentacles[_tokenID];
        if (_getTentacle(_outstandingTentacles, _tentacleID) == TENTACLE_STATE.CREATED) {
            revert ALREADY_CREATED(_tentacleID, _tokenID);
        }

        // Update to reflect that the tentacle has been created
        outstandingTentacles[_tokenID] = _setTentacle(_outstandingTentacles, _tentacleID);
    }

    function _create(
        uint8 _tentacleID,
        uint256[] memory _tokenIDs,
        address _beneficiary,
        uint256 _amount,
        IBPTentacleHelper _helperOverride
    ) internal {
        // NOTICE: this does not perform access control checks!

        // Get the tentacle that we are minting
        TentacleConfiguration memory _tentacle = tentacles[_tentacleID];

        if (address(_tentacle.tentacle) == address(0)) revert TENTACLE_NOT_SET(_tentacleID);

        // Figure out the helper we should use
        // TODO: add a reserved address (BPConstants.NO_HELPER_CONTRACT) that specifies the case for 'if there is a (unenforced) default I would still prefer the 0 address flow instead'
        IBPTentacleHelper _helper = _helperOverride;
        if (_tentacle.hasDefaultHelper && (_tentacle.forceDefault || address(_helper) == address(0))) {
            IBPTentacleHelper _defaultHelper = defaultTentacleHelper[_tentacleID];

            if (
                _tentacle.revertIfDefaultForcedAndOverriden && _helperOverride != _defaultHelper
                    && address(_helperOverride) != address(0)
            ) revert TENTACLE_HAS_DEFAULT_HELPER(_tentacleID);

            _helper = _defaultHelper;
        }

        // Perform the mint, either use the helper flow or the regular flow
        if (address(_helper) != address(0)) {
            // Mint to the helper
            _tentacle.tentacle.mint(address(_helper), _amount);
            // Call the helper to perform its actions
            _helper.createFor(_tentacleID, _tentacle.tentacle, _tokenIDs, _amount, _beneficiary);
        } else {
            // Call tentacle to mint tokens
            _tentacle.tentacle.mint(_beneficiary, _amount);
        }
    }

    function _destroy(uint8 _tentacleID, uint256 _tokenID, address _caller, address _from) internal {
        // NOTICE: this does not perform access control checks!

        // Get the value of the token
        uint256 _amount = stakingDelegate.stakingTokenBalance(_tokenID);

        bytes32 _outstandingTentacles = outstandingTentacles[_tokenID];
        if (_getTentacle(_outstandingTentacles, _tentacleID) == TENTACLE_STATE.CREATED) {
            revert ALREADY_CREATED(_tentacleID, _tokenID);
        }

        // Get the tentacle that we are burning for
        TentacleConfiguration memory _tentacleConfiguration = tentacles[_tentacleID];
        if (address(_tentacleConfiguration.tentacle) == address(0)) revert TENTACLE_NOT_SET(_tentacleID);

        // Call tentacle to burn tokens
        _tentacleConfiguration.tentacle.burn(_caller, _from, _amount);

        // Update to reflect that the tentacle has been destroyed
        outstandingTentacles[_tokenID] = _unsetTentacle(_outstandingTentacles, _tentacleID);
    }

    //*********************************************************************//
    // ------------------------- internal pure --------------------------- //
    //*********************************************************************//

    function _setTentacle(bytes32 _outstandingTentacles, uint8 _id) internal pure returns (bytes32 _updatedTentacles) {
        assembly {
            _updatedTentacles := or(shl(_id, 1), _outstandingTentacles)
        }
    }

    function _unsetTentacle(bytes32 _outstandingTentacles, uint8 _id)
        internal
        pure
        returns (bytes32 _updatedTentacles)
    {
        assembly {
            _updatedTentacles := and(shl(_id, 0), _outstandingTentacles)
        }
    }

    function _getTentacle(bytes32 _outstandingTentacles, uint8 _id) internal pure returns (TENTACLE_STATE _state) {
        assembly {
            _state := iszero(iszero(and(shl(_id, 0x1), _outstandingTentacles)))
        }
    }
}
