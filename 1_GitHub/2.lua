-- ============================================================
-- NOTIFICATION SYSTEM
-- ============================================================
local function Notify(msg) local s = "[BNTMOD VIP New] " .. tostring(msg)
pcall(function() if _G.BNTMODNotify then _G.BNTMODNotify(s) end end)
pcall(function() local sh = import("ScriptHelperClient") if sh and
sh.AddOnScreenDebugMessage then sh.AddOnScreenDebugMessage(s, -1, 3.0, {R=1,
G=1, B=0, A=1}, {X=1.2, Y=1.2}) end end) print(s) end

local _slua = rawget(_G, "slua")
local function Valid(obj) if not obj then return false end if _slua and
_slua.isValid then local ok, v = pcall(_slua.isValid, obj) if not ok or not v
then return false end end return true end

local BRPlayerCharacterBase = {
  ServerRPC = {},
  ClientRPC = {},
  MulticastRPC = {}
}
BRPlayerCharacterBase.ServerRPC.ServerRPC_NearDeathGiveupRescue = { Reliable = true, Params = {} }
BRPlayerCharacterBase.ServerRPC.ServerRPC_CarryDeadBox = { Reliable = true, Params = { UEnums.EPropertyClass.Object } }
BRPlayerCharacterBase.ServerRPC.RPC_Server_GmPlayAction = { Reliable = true, Params = { UEnums.EPropertyClass.Int } }
BRPlayerCharacterBase.MulticastRPC.MulticastRPC_GmPlayAction = { Reliable = true, Params = { UEnums.EPropertyClass.Int } }
BRPlayerCharacterBase.ClientRPC.RPC_Client_SetShouldCheckPassWall = { Reliable = true, Params = { UEnums.EPropertyClass.Bool } }

local ENetRole = import("ENetRole")
local EPawnState = import("EPawnState")
local GameplayData = require("GameLua.GameCore.Data.GameplayData")
local GamePlayTools = require("GameLua.Mod.BaseMod.Common.GamePlayTools")

local KismetSystemLibrary = import("KismetSystemLibrary")
local packageName = KismetSystemLibrary.GetGameBundleId()

if packageName ~= "com.tencent.ig" and packageName ~= "com.pubg.krmobile" and packageName ~= "com.rekoo.pubgm" and packageName ~= "com.vng.pubgmobile" and packageName ~= "com.tencent.igfit" then
    return
end
    
function BRPlayerCharacterBase:ctor() end

function BRPlayerCharacterBase:_PostConstruct()
  BRPlayerCharacterBase.__super._PostConstruct(self)
  self:InitAddSpecialMoveInfo()
  self.bCanNearDeathGiveup = true
end

function BRPlayerCharacterBase:ReceiveBeginPlay()
  BRPlayerCharacterBase.__super.ReceiveBeginPlay(self)
  self:AddControlEvent(self, "MovementModeChangedDelegate", self.HandleOnMovementModeChangedNew, self)
  if self:HasAuthority() and self:CheckAddCheckFallingDistanceComponent() then
    local CheckFallingDistanceComponent_C = import("CheckFallingDistanceComponent")
    if slua.isValid(CheckFallingDistanceComponent_C) and not slua.isValid(self:GetComponentByClass(CheckFallingDistanceComponent_C)) then
      Game:AddComponent(CheckFallingDistanceComponent_C, self, "CheckFallingDistanceComponent")
    end
  end
  if slua.isValid(self.STCharacterMovement) then
    self.STCharacterMovement.bPositiveBlowUp = true
  end
  if self.Role == ENetRole.ROLE_AutonomousProxy then
    self:AddControlEvent(self, "OnPawnStateDisabled", self.OnPawnStateChange, self)
    self:AddControlEvent(self, "OnPawnStateEnabled", self.OnPawnStateChange, self)
    self:AddControlEventConditionOnly(self, "OnAttrChangeEventDelegate", { AttrName = { "bCanSelfRescue" } }, self.CharacterAttrChangeEvent, self)
  end
  if Client then
    GameplayData.AddCharacter(self.Object)
    self:AddControlEvent(self, "OnAttachedToVehicle", self.HandleOnAttachedToVehicle, self)
    self:AddControlEvent(self, "OnDetachedFromVehicle", self.HandleOnDetachedFromVehicle, self)
  else
    self:AddCommonEventWithConditions(EVENTTYPE_INGAME_NORMAL, EVENTID_GAME_MODE_STATE_CHANGE, { [1] = "FinishedState" }, self.HandleFinishedState, self)
  end
end

function BRPlayerCharacterBase:HandleOnAttachedToVehicle(uVehicle)
  if not slua.isValid(uVehicle) then return end
  if self.Role == ENetRole.ROLE_SimulatedProxy then
    self:ClearAttachToVehicleTimer()
    self.nUpdatePlayerAttachToVehicleCount = 0
    self.nUpdatePlayerAttachToVehicleTimer = self:AddGameTimer(5, true, function()
      if slua.isValid(self.Object) and slua.isValid(uVehicle) then self:UpdatePlayerAttachToVehicle(uVehicle) end
    end)
    self.nFixMeshContainerTimer = self:AddGameTimer(3, true, function()
      if slua.isValid(self.Object) and slua.isValid(uVehicle) then self:FixMeshContainerOffsetIfNeeded(uVehicle) end
    end)
  end
end

function BRPlayerCharacterBase:HandleOnDetachedFromVehicle(uLastVehicle)
  if not slua.isValid(uLastVehicle) then return end
  if self.Role == ENetRole.ROLE_SimulatedProxy then
    self:ClearAttachToVehicleTimer()
    self.nUpdatePlayerAttachToVehicleCount = 0
  end
end

function BRPlayerCharacterBase:UpdatePlayerAttachToVehicle(uVehicle)
  if not slua.isValid(self.Object) or not slua.isValid(uVehicle) then return end
  if not slua.isValid(self.CapsuleComponent) or not slua.isValid(self.Mesh) or not slua.isValid(self.MeshContainer) then return end
  if not slua.isValid(self:GetCurrentVehicle()) then return end
  if Game:IsDriver(self.Object) then return end
  if not self.nUpdatePlayerAttachToVehicleCount then self.nUpdatePlayerAttachToVehicleCount = 0 end
  local ESTEPoseState = import("ESTEPoseState")
  local bStand = self.PoseState == ESTEPoseState.Stand
  local uActorRelativeLocation = self.CapsuleComponent:GetRelativeTransform():GetLocation()
  local uMeshRelativeLocation = self.Mesh:GetRelativeTransform():GetLocation()
  local uMeshContainerRelativeLocationZ = self.MeshContainer:GetRelativeTransform():GetLocation().Z
  local nCapsuleRadius = self.CapsuleComponent:GetScaledCapsuleRadius()
  local nCapsuleHalfHeight = self.CapsuleComponent:GetScaledCapsuleHalfHeight()
  local uMeshContainerExpectedZ = -1 * self.StandHalfHeight
  local nExpectedCapsuleRadius = self.StandRadius
  local nExpectedCapsuleHalfHeight = self.StandHalfHeight
  local uMeshExpectedRL = FVector(0, 0, 0)
  local uActorExpectedRL = FVector(0, 0, self.StandHalfHeight)
  local nTolerance = 1.0
  local bCapsuleRLCorrect = uActorRelativeLocation:Equals(uActorExpectedRL, nTolerance)
  local bMeshRLCorrect = uMeshRelativeLocation:Equals(uMeshExpectedRL, nTolerance)
  local bMeshContainerRLCorrect = nTolerance > math.abs(uMeshContainerRelativeLocationZ - uMeshContainerExpectedZ)
  local bCapsuleRadiusCorrect = nTolerance > math.abs(nCapsuleRadius - nExpectedCapsuleRadius)
  local bCapsuleHalfHeightCorrect = nTolerance > math.abs(nCapsuleHalfHeight - nExpectedCapsuleHalfHeight)
  local bAllCorrect = bStand and bCapsuleRLCorrect and bMeshRLCorrect and bMeshContainerRLCorrect and bCapsuleRadiusCorrect and bCapsuleHalfHeightCorrect
  if not bAllCorrect then
    self.nUpdatePlayerAttachToVehicleCount = self.nUpdatePlayerAttachToVehicleCount + 1
  else
    self.nUpdatePlayerAttachToVehicleCount = 0
  end
  if self.nUpdatePlayerAttachToVehicleCount >= 3 and not bAllCorrect then
    local GameplayData = require("GameLua.GameCore.Data.GameplayData")
    local uPlayerController = GameplayData.GetPlayerController()
    if uPlayerController.ReportCrashKitFeature and uPlayerController.ReportCrashKitFeature.ReportCharacterAttachedOnVehicleException then
      local sReportInfo = string.format("VehicleShapeType:%s PlayerKey:%s", tostring(uVehicle.VehicleShapeType), tostring(self.PlayerKey))
      uPlayerController.ReportCrashKitFeature:ReportCharacterAttachedOnVehicleException(sReportInfo)
    end
    self.nUpdatePlayerAttachToVehicleCount = 0
  end
end

function BRPlayerCharacterBase:FixMeshContainerOffsetIfNeeded(uVehicle)
  if not slua.isValid(self.Object) or not slua.isValid(uVehicle) then return end
  if not slua.isValid(self.MeshContainer) then return end
  if not slua.isValid(self:GetCurrentVehicle()) then return end
  if Game:IsDriver(self.Object) then return end
  local nTolerance = 1.0
  local uMeshContainerExpectedZ = -1 * self.StandHalfHeight
  local uMeshContainerRelativeLocationZ = self.MeshContainer:GetRelativeTransform():GetLocation().Z
  if nTolerance <= math.abs(uMeshContainerRelativeLocationZ - uMeshContainerExpectedZ) then
    self:SetMeshContainerOffsetZ(uMeshContainerExpectedZ)
  end
end

function BRPlayerCharacterBase:ClearAttachToVehicleTimer()
  if self.nUpdatePlayerAttachToVehicleTimer then
    self:RemoveGameTimer(self.nUpdatePlayerAttachToVehicleTimer)
    self.nUpdatePlayerAttachToVehicleTimer = nil
  end
  if self.nFixMeshContainerTimer then
    self:RemoveGameTimer(self.nFixMeshContainerTimer)
    self.nFixMeshContainerTimer = nil
  end
end

function BRPlayerCharacterBase:CharacterAttrChangeEvent(uPawn, AttrName, AttrVal)
  BRPlayerCharacterBase.__super.CharacterAttrChangeEvent(self, uPawn, AttrName, AttrVal)
  if self.Object ~= uPawn then return end
  if self.Role == ENetRole.ROLE_AutonomousProxy and AttrName == "bCanSelfRescue" then
    local uPlayerController = self:GetPlayerControllerSafety()
    if slua.isValid(uPlayerController) then
      uPlayerController:BroadcastUIMessage("UIMsg_CanSelfRescue", 0, "", "")
    end
  end
end

function BRPlayerCharacterBase:OnPawnStateChange(PawnState)
  local EPawnState = import("EPawnState")
  if PawnState == EPawnState.SwitchPP then
    local uPlayerController = self:GetPlayerControllerSafety()
    if slua.isValid(uPlayerController) then
      uPlayerController:BroadcastUIMessage("UIMsg_FPPModeChange", 0, "", "")
    end
  end
end

function BRPlayerCharacterBase:HandleFinishedState()
  if slua.isValid(self.STCharacterMovement) and self.STCharacterMovement.SetDynamicSimpleQueryConfig then
    self.STCharacterMovement:SetDynamicSimpleQueryConfig(false)
  end
end

function BRPlayerCharacterBase:CheckAddCheckFallingDistanceComponent()
  if CGameMode and CGameMode.GameModeType and CGameState and CGameState.GameModeID then
    local EGameModeType = import("EGameModeType")
    local MatchModeIds = require("GameLua.Mod.BaseMod.GamePlay.Config.MatchModeIdsConfig")
    local GameModeType = CGameMode.GameModeType
    local GameModeID = tonumber(CGameState.GameModeID)
    local bModeTypeSatisfy = GameModeType == EGameModeType.ETypicalGameMode or GameModeType == EGameModeType.EFourInOneGameMode or GameModeType == EGameModeType.EHeavyWeaponGameMode
    local bModeIDSatisfy = not MatchModeIds[GameModeID]
    return bModeTypeSatisfy and bModeIDSatisfy
  end
  return false
end

function BRPlayerCharacterBase:LuaHandleParachuteStateChanged(LastParachuteState, NewParachuteState)
  BRPlayerCharacterBase.__super.LuaHandleParachuteStateChanged(self, LastParachuteState, NewParachuteState)
  local EParachuteState = import("EParachuteState")
  if not Client then
    local uCurrentPlayerControl = self:GetPlayerControllerSafety()
    if slua.isValid(uCurrentPlayerControl) and uCurrentPlayerControl.CheckParachuteOpenFeature then
      if NewParachuteState == EParachuteState.PS_Opening then
        if uCurrentPlayerControl.CheckParachuteOpenFeature.SatrtCheckShowParachuteCloseUI then
          uCurrentPlayerControl.CheckParachuteOpenFeature:SatrtCheckShowParachuteCloseUI()
        end
      elseif NewParachuteState == EParachuteState.PS_None then
        if uCurrentPlayerControl.CheckParachuteOpenFeature.RecoverParachuteOpenParam then
          uCurrentPlayerControl.CheckParachuteOpenFeature:RecoverParachuteOpenParam()
        end
        if uCurrentPlayerControl.CheckParachuteOpenFeature.ClearTimerAndState then
          uCurrentPlayerControl.CheckParachuteOpenFeature:ClearTimerAndState()
        end
      end
    end
  end
end

function BRPlayerCharacterBase:OnLanded()
  if self.HandleOnLanded then self:HandleOnLanded(-1) end
  if not Client then
    local uCurrentPlayerControl = self:GetPlayerControllerSafety()
    if slua.isValid(uCurrentPlayerControl) and uCurrentPlayerControl.CheckParachuteOpenFeature then
      if uCurrentPlayerControl.CheckParachuteOpenFeature.ClearTimerAndState then
        uCurrentPlayerControl.CheckParachuteOpenFeature:ClearTimerAndState()
      end
      if uCurrentPlayerControl.CheckParachuteOpenFeature.ResetCheckShowUI then
        uCurrentPlayerControl.CheckParachuteOpenFeature:ResetCheckShowUI()
      end
    end
  end
end

function BRPlayerCharacterBase:ReceiveEndPlay(EndPlayReason)
  BRPlayerCharacterBase.__super.ReceiveEndPlay(self, EndPlayReason)
  if Client then GameplayData.RemoveCharacter(self.Object) end
end

function BRPlayerCharacterBase:IsWarGameMode()
  local GameplayData = require("GameLua.GameCore.Data.GameplayData")
  local uGameState = GameplayData:GetGameState()
  local STExtraGameStateBase = import("STExtraGameStateBase")
  if slua.isValid(uGameState) and Game:IsClassOf(uGameState, STExtraGameStateBase) then
    local EGameModeType = import("EGameModeType")
    return uGameState.GameModeType == EGameModeType.EWarGameMode
  end
  return false
end

function BRPlayerCharacterBase:BPOnRecycled() if Client then self:ResetMeshRelativeLocationAndRotation() end end
function BRPlayerCharacterBase:BPOnRespawned() if Client then self:ResetMeshRelativeLocationAndRotation() end end

function BRPlayerCharacterBase:ReceiveOnRecycle()
  if Client then
    self:ResetMeshRelativeLocationAndRotation()
    GameplayData.RemoveCharacter(self.Object)
  end
end

function BRPlayerCharacterBase:ReceiveOnSpawn()
  if Client then
    self:ResetMeshRelativeLocationAndRotation()
    GameplayData.AddCharacter(self.Object)
  end
end

function BRPlayerCharacterBase:ResetMeshRelativeLocationAndRotation()
  if Game:IsValid(self.Object) and Game:IsValid(self.Mesh) then
    local uDefaultMeshRot = FRotator(0, -90, 0)
    local uDefaultMeshRelativeLoc = FVector(0, 0, 0)
    if self.Mesh.K2_SetRelativeRotation then
      self.Mesh:K2_SetRelativeRotation(uDefaultMeshRot, false, nil, false)
    end
    self:CacheInitialMeshOffset(uDefaultMeshRelativeLoc, uDefaultMeshRot)
  end
end

function BRPlayerCharacterBase:HandleOnMovementModeChangedNew()
  local EMovementMode = import("EMovementMode")
  if Game:IsValid(self.STCharacterMovement) and self.STCharacterMovement.MovementMode == EMovementMode.MOVE_Swimming and self:CheckBaseIsMoveable() then
    self.CharacterMovement:SetBase(nil, "", true)
  end
  if self.Role == ENetRole.ROLE_AutonomousProxy and Game:IsValid(self.STCharacterMovement) and self.STCharacterMovement.MovementMode == EMovementMode.MOVE_Walking and UIManager.UI_Config_InGame.ParachuteOpenUI then
    UIManager.CloseUI(UIManager.UI_Config_InGame.ParachuteOpenUI)
  end
end

function BRPlayerCharacterBase:BPOnMissPlayerDamageRecord() end

BRPlayerCharacterBase.ClientRPC.ClientRPC_TriggerHighlightMoment = { Reliable = true, Params = { UEnums.EPropertyClass.UInt32, UEnums.EPropertyClass.UInt32 } }

function BRPlayerCharacterBase:ClientRPC_TriggerHighlightMoment(Type, Param)
  EventSystem:postEvent(EVENTTYPE_INGAME, EVENTID_INGAME_TRIGGER_HIGHLIGHT_MOMENT, Type, Param)
end

function BRPlayerCharacterBase:ParachuteJump()
  local uPlayerController = self:GetControllerSafety()
  if slua.isValid(uPlayerController) then
    if not self:GetEnsure() then
      local EStateType = import("EStateType")
      if uPlayerController:GetCurrentStateType() ~= EStateType.State_ParachuteJump and uPlayerController:GetCurrentStateType() ~= EStateType.State_ParachuteOpen then
        local ESTEPoseState = import("ESTEPoseState")
        self:SwitchPoseState(ESTEPoseState.Stand, true, true, true, false)
        uPlayerController:ReInitParachuteItem()
        uPlayerController:ServerChangeStatePC(EStateType.State_ParachuteJump)
      end
    else
      EventSystem:postEvent(EVENTTYPE_INGAME_NORMAL, EVENTID_AI_CALL_PARACHUTE_JUMP, self.Object)
    end
  end
end

function BRPlayerCharacterBase:CheckForbidFlaregun()
  local uPlayerState = self:GetPlayerStateSafety()
  if not slua.isValid(uPlayerState) then return false end
  if uPlayerState.CanUseFlaregun == false and self:IsLocallyControlled() then
    local uPlayerController = self:GetPlayerControllerSafety()
    if slua.isValid(uPlayerController) then uPlayerController:DisplayGameTipWithMsgID(48532) end
  end
  return not uPlayerState.CanUseFlaregun
end

function BRPlayerCharacterBase:ServerRPC_NearDeathGiveupRescue() self:HandleNearDeathGiveupRescue() end

function BRPlayerCharacterBase:HandleNearDeathGiveupRescue()
  local uNearDeathComp = self.NearDeatchComponent
  if self:IsNearDeath() and slua.isValid(uNearDeathComp) and self.bCanNearDeathGiveup == true then
    local uPlayerState = self:GetPlayerStateSafety()
    if slua.isValid(uPlayerState) then uPlayerState:AddGeneralCount(1613, 1, false) end
    uNearDeathComp:TriggerGotoDieExplictly(self.Object)
  end
end

function BRPlayerCharacterBase:RPC_Server_GmPlayAction(actionId)
  local USTExtraBlueprintFunctionLibrary = import("STExtraBlueprintFunctionLibrary")
  if USTExtraBlueprintFunctionLibrary.IsDevelopment() then self:MulticastRPC_GmPlayAction(actionId) end
end

function BRPlayerCharacterBase:MulticastRPC_GmPlayAction(actionId)
  if not Client then return end
  local uPlayEmoteComp = self:GetPlayEmoteComponent()
  if not slua.isValid(uPlayEmoteComp) then return end
  local LogFilter = require("common.log_filter")
  LogFilter.SetLogTreeEnable(true)
  local animCfg = CDataTable.GetTableData("EmoteBPTable", actionId)
  if not animCfg then return end
  local handlePath = animCfg.Path
  local EmoteHandleAsset = slua.loadObject(handlePath)
  local assetsArray = slua.Array(UEnums.EPropertyClass.Struct, import("/Script/CoreUObject.SoftObjectPath"))
  local handle = EmoteHandleAsset()
  uPlayEmoteComp:OnLoadEmoteAssetBegin(handle, actionId, assetsArray, "")
  local tb = FuncUtil.LuaArrayToTable(assetsArray)
  local asset_util = require("common.asset_util")
  local loadLater = function() uPlayEmoteComp:OnLoadEmoteAssetEnd(handle, actionId, 0) end
  asset_util.GetAssetsArrayAsyncParallel(tb, loadLater)
end

function BRPlayerCharacterBase:RPC_Client_SetShouldCheckPassWall(bServerSyncShouldCheckPassWall)
  if slua.isValid(self.ParachuteComponent) then
    self.ParachuteComponent.bServerSyncShouldCheckPassWall = bServerSyncShouldCheckPassWall
  end
end

function BRPlayerCharacterBase:OnPlayerEnterCarryBoxState()
  self.Super:OnPlayerEnterCarryBoxState()
  if self.CarryDeadBoxFeature then self.CarryDeadBoxFeature:OnPlayerEnterCarryBoxState() end
end

function BRPlayerCharacterBase:OnPlayerLeaveCarryBoxState(bInIsInterrupt)
  self.Super:OnPlayerLeaveCarryBoxState(bInIsInterrupt)
  if self.CarryDeadBoxFeature then self.CarryDeadBoxFeature:OnPlayerLeaveCarryBoxState(bInIsInterrupt) end
end

function BRPlayerCharacterBase:ServerRPC_CarryDeadBox(uInDeadBox)
  if slua.isValid(uInDeadBox) and Game:IsClassOf(uInDeadBox, import("/Script/ShadowTrackerExtra.PlayerTombBox")) and self.CarryDeadBoxFeature then
    self.CarryDeadBoxFeature:CarryDeadBox(uInDeadBox)
  end
end

function BRPlayerCharacterBase:SetAreaID(AreaID) self:SetAttrValue("AreaID", AreaID, -1) end
function BRPlayerCharacterBase:GetAreaID() return math.floor(self:GetAttrValue("AreaID") + 0.5) end
function BRPlayerCharacterBase:CannotChangeIntoPetSpectator() return self.bCannotChangeIntoPetSpectator end

function BRPlayerCharacterBase:DoModChangeToBT()
  if self:HasState(EPawnState.SpecialSuit) then self:TriggerEntrySkillWithID(4301101, true) end
end

function BRPlayerCharacterBase:SwitchCameraToParachuteOpening()
  self.Super:SwitchCameraToParachuteOpening()
  if self.ParachuteFormation and self.ParachuteFormation.ShouldApplyFormationCamera and self.ParachuteFormation:ShouldApplyFormationCamera() then
    self.ParachuteFormation:OverlayFormationCameraParams()
  end
end

function BRPlayerCharacterBase:SwitchCameraToParachuteFalling()
  self.Super:SwitchCameraToParachuteFalling()
  if self.ParachuteFormation and self.ParachuteFormation.ShouldApplyFormationCamera and self.ParachuteFormation:ShouldApplyFormationCamera() then
    self.ParachuteFormation:OverlayFormationCameraParams()
  end
end

function BRPlayerCharacterBase:SwitchCameraToNormal()
  self.Super:SwitchCameraToNormal()
  if self.ParachuteFormation and self.ParachuteFormation.OnLandingClearFormationCamera then
    self.ParachuteFormation:OnLandingClearFormationCamera()
  end
end

function BRPlayerCharacterBase:SwitchWeaponCheck(Slot, IgnoreState)
  if self:HasState(EPawnState.AttachToOther) then
    local Weapon = self:GetWeaponBySlot(Slot)
    if slua.isValid(Weapon) then
      local WeaponID = Weapon:GetWeaponID()
      local AttachToOtherConfig = GamePlayTools.GetCurrentConfig("AttachToOtherConfig")
      if AttachToOtherConfig and AttachToOtherConfig.CheckIsWeaponInBlackList and AttachToOtherConfig.CheckIsWeaponInBlackList(WeaponID) then
        local uPlayerController = self:GetPlayerControllerSafety()
        if Client and slua.isValid(uPlayerController) and uPlayerController.Role == ENetRole.ROLE_AutonomousProxy then
          uPlayerController:DisplayGameTipWithMsgID(47306)
        end
        return false
      end
    end
  end
  return self.Super:SwitchWeaponCheck(Slot, IgnoreState)
end

-- ==============================================================================
-- START MOD LOGIC
-- ==============================================================================

-- LOW-END OPTIMIZED CONSTANTS
local LOW_END_MODE = true

local LOOP_INTERVAL       = LOW_END_MODE and 0.6 or 0.4
local AIMBOT_INTERVAL     = LOW_END_MODE and 0.033 or 0.016
local SCAN_INTERVAL       = LOW_END_MODE and 1.5 or 0.8
local MESH_CACHE_TIME     = LOW_END_MODE and 5.0 or 3.0
local ESP_MAX_DIST        = LOW_END_MODE and 300 or 400
local BONE_LOD_DIST       = LOW_END_MODE and 30 or 50
local ESP6_UPDATE_INTERVAL= LOW_END_MODE and 0.1 or 0.05

local C_GREEN = {R=0, G=255, B=0, A=255}
local C_RED = {R=255, G=0, B=0, A=255}
local C_CYAN = {R=0, G=255, B=255, A=255}
local C_YELLOW = {R=255, G=255, B=0, A=255}
local C_WHITE = {R=255, G=255, B=255, A=255}

local GLOBAL_BONE_LIST = {
    "head", "neck_01", "pelvis",
    "upperarm_r", "lowerarm_r", "hand_r",
    "upperarm_l", "lowerarm_l", "hand_l",
    "thigh_l", "calf_l", "foot_l",
    "thigh_r", "calf_r", "foot_r"
}
local GLOBAL_BONE_LIST_LOW = { "head", "pelvis", "neck_01" }

_G.BNTMODConfig = _G.BNTMODConfig or { 
    EspVip = false, UnlockFPS = false, EspLuckyEgg = false, IpadView = false, EspStatic = false,
    EspEnemyCount = false, EspWeaponStatus = false,
    CustomAimbot = false, CustomAimbotClose = false, 
    CustomHRecoil = false, CustomVRecoil = false, LessShake = false, 
    RemoveGrass = false, RemoveTrees = false, 
    -- WhiteBody REMOVED
    ColorBodyNew = false,
    Crosshair = false, Accuracy = false, BlackSky = false,
    MortarAim = false, MortarVisCheck = false, EspWeapon = false,
    Weapon_M416 = false, Weapon_AKM = false, Weapon_SCAR = false,
    Weapon_M16A4 = false, Weapon_M762 = false, Weapon_Groza = false,
    Weapon_AUG = false, Weapon_QBZ = false, Weapon_G36C = false,
    Weapon_FAMAS = false, Weapon_Kar98k = false, Weapon_M24 = false,
    Weapon_AWM = false, Weapon_SKS = false, Weapon_SLR = false,
    Weapon_Mini14 = false, Weapon_Mk14 = false, Weapon_VSS = false,
    Weapon_QBU = false, Weapon_Mosin = false, Weapon_AMR = false,
    Weapon_UMP45 = false, Weapon_UZI = false, Weapon_Vector = false,
    Weapon_Tommy = false, Weapon_Bizon = false, Weapon_MP5K = false,
    Weapon_P90 = false, Weapon_M249 = false, Weapon_DP28 = false,
    Weapon_MG3 = false, Weapon_S686 = false, Weapon_S1897 = false,
    Weapon_S12K = false, Weapon_DBS = false, Weapon_Origin = false,
    Weapon_Crossbow = false, Weapon_Deagle = false, Weapon_Flare = false,
    Veh_MiradoOrange = false, Veh_MiradoRed = false, Veh_Dacia = false,
    Veh_Buggy = false, Veh_UAZ_Old = false, Veh_Motorcycle = false,
    Veh_Helicopter = false, Veh_BRDM = false, Veh_Minibus = false,
    Veh_MonsterTruck = false, Veh_UAZ = false, Veh_Pickup = false,
    AimTouchEnable = false, AimTouchHipIgKnock = true, AimTouchHipIgBot = true,
    AimTouchSGIgKnock = true, AimTouchSGIgBot = true, AimTouchHipVisCheck = true,
    AimTouchSGVisCheck = true, AimTouchHipfire = false, AimTouchSG = false,
    AimTouchSGAutoFire = false, AimTouchScopeAll = false, AimTouchScopeIgKnock = true,
    AimTouchScopeIgBot = true, AimTouchScopeVisCheck = true, AimTouchScopeSniper = false,
    AimTouchSniperIgKnock = true, AimTouchSniperIgBot = true, AimTouchSniperVisCheck = true,
}

_G.BNTMODState = _G.BNTMODState or { 
    LoopToken = 0, AimbotLoopToken = 0, NativeESPReady = false,
    GraphicsUnlocked = false, MenuStep = 0, LastCmdTime = 0,
    TrackedMarks = {}, EnemyMarks = {}, LastAimbotCheckTime = 0,
    CustomTextData = nil, LastAimbotConfigString = "",
    PrevGraphicsState = {},
}

local limitTime = os.time({ year = 2027, month = 10, day = 1, hour = 23, min = 59, sec = 0 })
local currentTime = os.time(os.date("!*t"))
local isExpired = false

pcall(function()
    local fileName = ".sys_time_cache"
    local paths = {
        "//storage/emulated/0/Android/data/com.tencent.ig/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "//storage/emulated/0/Android/data/com.pubg.krmobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "//storage/emulated/0/Android/data/com.pubg.imobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "//storage/emulated/0/Android/data/com.vng.pubgmobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "//storage/emulated/0/Android/data/com.rekoo.pubgm/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,                
        "//storage/emulated/0/Android/data/com.tencent.igfit/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "../../ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
    }
    local tm = package.loaded["client.logic.common.TimeManager"]
    if not tm then 
        local s, r = pcall(require, "client.logic.common.TimeManager")
        if s and r then tm = r end
    end
    if tm and type(tm.GetServerTime) == "function" then
        local serverTime = tm.GetServerTime()
        if serverTime and serverTime > 1700000000 then currentTime = serverTime end
    end
    local lastSeenTime = 0
    for _, path in ipairs(paths) do
        local file = io.open(path, "r")
        if file then
            local data = file:read("*a")
            local savedTime = tonumber(data) or 0
            if savedTime > lastSeenTime then lastSeenTime = savedTime end
            file:close()
        end
    end
    if currentTime < lastSeenTime then currentTime = lastSeenTime
    else
        for _, path in ipairs(paths) do
            local file = io.open(path, "w")
            if file then file:write(tostring(currentTime)); file:close() end
        end
    end
end)

isExpired = (currentTime > limitTime)

-- ========================================== 
-- MAP MARK
-- ========================================== 
local function SafeAddMark(id, pos, z, str, size, actor)
    local mark = nil
    pcall(function()
        local InGameMarkTools = require("GameLua.Mod.BaseMod.Common.InGameMarkTools")
        if InGameMarkTools and InGameMarkTools.ClientAddMapMark then
            mark = InGameMarkTools.ClientAddMapMark(id, pos, z, str, size, actor)
            if mark then _G.BNTMODState.TrackedMarks[mark] = true end
        end
    end)
    return mark
end

local function SafeRemoveMark(mark)
    if not mark then return end
    pcall(function()
        local InGameMarkTools = require("GameLua.Mod.BaseMod.Common.InGameMarkTools")
        if InGameMarkTools and InGameMarkTools.HideMapMark then InGameMarkTools.HideMapMark(mark) end
        if InGameMarkTools and InGameMarkTools.RemoveMapMark then InGameMarkTools.RemoveMapMark(mark) end
    end)
    _G.BNTMODState.TrackedMarks[mark] = nil
end

local function GetSafeEnemyKey(enemy)
    if Valid(enemy) then
        if enemy.PlayerKey then return tostring(enemy.PlayerKey) end
        if type(enemy.GetUniqueID) == "function" then return tostring(enemy:GetUniqueID()) end
    end
    return tostring(enemy)
end

local function CheckIsAI(pawn, markData)
    if markData.AK_IS_BOT ~= nil then return markData.AK_IS_BOT, true end
    local isAI = false
    local hasChecked = false
    pcall(function()
        if pawn.bIsAI == true or pawn.IsAI == true then isAI = true; hasChecked = true end
        if type(pawn.IsBot) == "function" and pawn:IsBot() then isAI = true; hasChecked = true end
        local pState = pawn.PlayerState or (type(pawn.GetPlayerState) == "function" and pawn:GetPlayerState())
        if Valid(pState) then
            hasChecked = true
            if pState.bIsABot == true or pState.bIsBot == true then isAI = true end
        end
        if not isAI then
            local name = pawn.PlayerName or (type(pawn.GetPlayerName) == "function" and pawn:GetPlayerName()) or ""
            if name ~= "" and (name:find("Cobra") or name:find("Target") or name:find("bot_") or name:find("b_")) then
                isAI = true; hasChecked = true
            end
        end
    end)
    if hasChecked then markData.AK_IS_BOT = isAI end
    return isAI, hasChecked
end

-- ========================================== 
-- CONFIG STORAGE
-- ========================================== 
local function GetConfigPaths(fileName)
    local paths = {
        "//storage/emulated/0/Android/data/com.tencent.ig/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.rekoo.pubgm/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,                
        "//storage/emulated/0/Android/data/com.vng.pubgmobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.pubg.krmobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.rekoo.pubgm/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.pubg.imobile/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "//storage/emulated/0/Android/data/com.tencent.igfit/files/UE4Game/ShadowTrackerExtra/ShadowTrackerExtra/Saved/SaveGames/" .. fileName,
        "/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "/Documents/ShadowTrackerExtra/Saved/Paks/puffer_temp/" .. fileName,
        "ShadowTrackerExtra/Saved/Paks/" .. fileName,
        "../../ShadowTrackerExtra/Saved/Paks/" .. fileName,
        fileName
    }
    pcall(function()
        if os and os.getenv then
            local homeDir = os.getenv("HOME")
            if homeDir and homeDir ~= "" then
                table.insert(paths, 1, homeDir .. "/Documents/ShadowTrackerExtra/Saved/Paks/" .. fileName)
            end
        end
    end)
    return paths
end

local ConfigFileName = "GFEyollo_SAFE.txt"
_G.LastConfigSaveStr = ""

_G.SaveModSettings = function()
    pcall(function()
        local data = "return {\nBNTMODConfig = {\n"
        for k, v in pairs(_G.BNTMODConfig or {}) do
            data = data .. "  [\"" .. tostring(k) .. "\"] = " .. tostring(v) .. ",\n"
        end
        data = data .. "},\nCustomTextData = {\n"
        if _G.BNTMODState and _G.BNTMODState.CustomTextData then
            for k, v in pairs(_G.BNTMODState.CustomTextData) do
                data = data .. "  [\"" .. tostring(k) .. "\"] = " .. tostring(v) .. ",\n"
            end
        end
        data = data .. "}\n}"
        if data == _G.LastConfigSaveStr then return end
        _G.LastConfigSaveStr = data
        local paths = GetConfigPaths(ConfigFileName)
        for _, path in ipairs(paths) do
            local file = io.open(path, "w")
            if file then file:write(data); file:close(); break end
        end
    end)
end

_G.LoadModSettings = function()
    pcall(function()
        local paths = GetConfigPaths(ConfigFileName)
        local content = nil
        for _, path in ipairs(paths) do
            local file = io.open(path, "r")
            if file then content = file:read("*a"); file:close(); break end
        end
        if content then
            local func = load(content)
            if func then
                local savedData = func()
                if savedData and type(savedData) == "table" then
                    if savedData.BNTMODConfig then
                        for k, v in pairs(savedData.BNTMODConfig) do _G.BNTMODConfig[k] = v end
                    end
                    if savedData.CustomTextData then
                        _G.BNTMODState.CustomTextData = _G.BNTMODState.CustomTextData or {}
                        for k, v in pairs(savedData.CustomTextData) do _G.BNTMODState.CustomTextData[k] = v end
                    end
                end
            end
        end
        _G.SaveModSettings() 
    end)
end

local function AutoSaveLoop()
    pcall(function() if _G.SaveModSettings then _G.SaveModSettings() end end)
    pcall(function()
        local okTicker, ticker = pcall(require, "common.time_ticker") 
        if okTicker and ticker and ticker.AddTimerOnce then 
            ticker.AddTimerOnce(5.0, AutoSaveLoop)
        end
    end)
end

if not _G.ModConfigLoaded then
    _G.LoadModSettings()
    AutoSaveLoop()
    _G.ModConfigLoaded = true
end

_G.ReadLiveConfig = function() if _G.SaveModSettings then _G.SaveModSettings() end end

-- ========================================== 
-- VIP MENU SYSTEM
-- ========================================== 
function _G.InitModMenuTab()
    if _G.ModMenuInitialized then return end
    _G.ModMenuInitialized = true

    _G.BNTMODState.CustomTextData = _G.BNTMODState.CustomTextData or {
        OuterSpeed = 10, InnerSpeed = 10, OuterRecoil = 0, HRecoil = 0.3, VRecoil = 0.3, IpadViewFOV = 120,
        AimTouchHipPrio = 1, AimTouchHipBone = 1, AimTouchHipCond = 1, AimTouchHipSpeed = 50, AimTouchHipFOV = 30, AimTouchHipDist = 250,
        AimTouchSGPrio = 1, AimTouchSGBone = 2, AimTouchSGCond = 1, AimTouchSGSpeed = 80, AimTouchSGFOV = 40, AimTouchSGDist = 30,
        AimTouchScopePrio = 1, AimTouchScopeBone = 2, AimTouchScopeCond = 1, AimTouchScopeSpeed = 40, AimTouchScopeFOV = 20, AimTouchScopeDist = 300, AimTouchScopePred = 0, AimTouchScopeRecoil = 0,
        AimTouchSniperPrio = 1, AimTouchSniperBone = 1, AimTouchSniperCond = 2, AimTouchSniperSpeed = 30, AimTouchSniperFOV = 20, AimTouchSniperDist = 400, AimTouchSniperPred = 0, MortarCond = 2, MortarSpeed = 2, MortarFOV = 2, MortarDist = 2,
    }

    local LocUtil = _G.LocUtil
    if not LocUtil and package.loaded["client.common.LocUtil"] then
        LocUtil = require("client.common.LocUtil")
    end
    if LocUtil and not LocUtil._IsModMenuHooked then
        local old_get = LocUtil.GetLocalizeResStr
        LocUtil.GetLocalizeResStr = function(id)
            if type(id) == "string" and not tonumber(id) then return id end
            return old_get(id)
        end
        LocUtil._IsModMenuHooked = true
    end

    local SettingPageDefine = require("client.logic.NewSetting.SettingPageDefine")
    local SettingCatalog = require("client.logic.NewSetting.SettingCatalog")
    
    if not SettingPageDefine.ModMenu then
        local AliasMap = require("client.slua.umg.NewSetting.Item.AliasMap") 
        
        local StackIteam = {
            { Key = "ModMenu_ESP1", UI = AliasMap.TitleSwitcher, Text = "▶ ESP (AUTO SETUP)", GetFunc = function() return _G.BNTMODConfig.EspVip end, SetFunc = function(c,v) _G.BNTMODConfig.EspVip = v return true end },
            { Key = "ModMenu_EspLuckyEgg", UI = AliasMap.TitleSwitcher, Text = "▶ LUCKY EGG ESP", GetFunc = function() return _G.BNTMODConfig.EspLuckyEgg end, SetFunc = function(c,v) _G.BNTMODConfig.EspLuckyEgg = v if not v then _G.CachedLuckyEggs = {} else _G.LastScanLuckyEggTime = 0 end return true end },
            { Key = "ModMenu_EspStatic_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ PLAYER INFO", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.EspStatic end, SetFunc = function(c,v) _G.BNTMODConfig.EspStatic = v return true end },
            { Key = "ModMenu_EspEnemyCount", UI = AliasMap.Switcher, Text = "   ESP ENEMY COUNT", ExpandHandle = "ModMenu_EspStatic_Ex", GetFunc = function() return _G.BNTMODConfig.EspEnemyCount end, SetFunc = function(c,v) _G.BNTMODConfig.EspEnemyCount = v return true end },
            { Key = "ModMenu_EspWeaponStatus", UI = AliasMap.Switcher, Text = "   ESP WEAPON & STATUS ENEMY", ExpandHandle = "ModMenu_EspStatic_Ex", GetFunc = function() return _G.BNTMODConfig.EspWeaponStatus end, SetFunc = function(c,v) _G.BNTMODConfig.EspWeaponStatus = v return true end },
            { Key = "ModMenu_Rifile_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ RIFLE", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.EspRifleCategory or false end, SetFunc = function(c,v) _G.BNTMODConfig.EspRifleCategory = v return true end },
            { Key = "ModMenu_Weapon_M416", UI = AliasMap.Switcher, Text = "M416", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_M416 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_M416 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_AKM", UI = AliasMap.Switcher, Text = "AKM", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_AKM end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_AKM = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_SCAR", UI = AliasMap.Switcher, Text = "SCAR-L", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_SCAR end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_SCAR = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_M16A4", UI = AliasMap.Switcher, Text = "M16A4", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_M16A4 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_M16A4 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_M762", UI = AliasMap.Switcher, Text = "Beryl M762", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_M762 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_M762 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Groza", UI = AliasMap.Switcher, Text = "Groza", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Groza end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Groza = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_AUG", UI = AliasMap.Switcher, Text = "AUG", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_AUG end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_AUG = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_QBZ", UI = AliasMap.Switcher, Text = "QBZ", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_QBZ end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_QBZ = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_G36C", UI = AliasMap.Switcher, Text = "G36C", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_G36C end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_G36C = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_FAMAS", UI = AliasMap.Switcher, Text = "FAMAS", ExpandHandle = "ModMenu_Rifile_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_FAMAS end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_FAMAS = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Sniper_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ SNIPER & DMR", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.EspSniperCategory or false end, SetFunc = function(c,v) _G.BNTMODConfig.EspSniperCategory = v return true end },
            { Key = "ModMenu_Weapon_Kar98k", UI = AliasMap.Switcher, Text = "Kar98k", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Kar98k end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Kar98k = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_M24", UI = AliasMap.Switcher, Text = "M24", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_M24 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_M24 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_AWM", UI = AliasMap.Switcher, Text = "AWM", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_AWM end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_AWM = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_SKS", UI = AliasMap.Switcher, Text = "SKS", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_SKS end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_SKS = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_SLR", UI = AliasMap.Switcher, Text = "SLR", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_SLR end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_SLR = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Mini14", UI = AliasMap.Switcher, Text = "Mini14", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Mini14 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Mini14 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Mk14", UI = AliasMap.Switcher, Text = "Mk14", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Mk14 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Mk14 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_VSS", UI = AliasMap.Switcher, Text = "VSS", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_VSS end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_VSS = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_QBU", UI = AliasMap.Switcher, Text = "QBU", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_QBU end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_QBU = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Mosin", UI = AliasMap.Switcher, Text = "Mosin Nagant", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Mosin end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Mosin = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_AMR", UI = AliasMap.Switcher, Text = "Lynx AMR", ExpandHandle = "ModMenu_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_AMR end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_AMR = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_SMG_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ SMG & LMG", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.EspSMGCategory or false end, SetFunc = function(c,v) _G.BNTMODConfig.EspSMGCategory = v return true end },
            { Key = "ModMenu_Weapon_UMP45", UI = AliasMap.Switcher, Text = "UMP45", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_UMP45 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_UMP45 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_UZI", UI = AliasMap.Switcher, Text = "Micro UZI", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_UZI end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_UZI = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Vector", UI = AliasMap.Switcher, Text = "Vector", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Vector end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Vector = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Tommy", UI = AliasMap.Switcher, Text = "Tommy Gun", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Tommy end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Tommy = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Bizon", UI = AliasMap.Switcher, Text = "PP-19 Bizon", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Bizon end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Bizon = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_MP5K", UI = AliasMap.Switcher, Text = "MP5K", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_MP5K end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_MP5K = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_P90", UI = AliasMap.Switcher, Text = "P90", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_P90 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_P90 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_M249", UI = AliasMap.Switcher, Text = "M249", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_M249 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_M249 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_DP28", UI = AliasMap.Switcher, Text = "DP-28", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_DP28 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_DP28 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_MG3", UI = AliasMap.Switcher, Text = "MG3", ExpandHandle = "ModMenu_SMG_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_MG3 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_MG3 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Shotgun_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ SHOTGUN & PISTOL", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.EspShotgunCategory or false end, SetFunc = function(c,v) _G.BNTMODConfig.EspShotgunCategory = v return true end },
            { Key = "ModMenu_Weapon_S686", UI = AliasMap.Switcher, Text = "S686", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_S686 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_S686 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_S1897", UI = AliasMap.Switcher, Text = "S1897", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_S1897 end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_S1897 = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_S12K", UI = AliasMap.Switcher, Text = "S12K", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_S12K end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_S12K = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_DBS", UI = AliasMap.Switcher, Text = "DBS", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_DBS end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_DBS = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Origin", UI = AliasMap.Switcher, Text = "Origin 12", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Origin end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Origin = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Crossbow", UI = AliasMap.Switcher, Text = "Crossbow", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Crossbow end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Crossbow = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Deagle", UI = AliasMap.Switcher, Text = "Desert Eagle", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Deagle end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Deagle = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Weapon_Flare", UI = AliasMap.Switcher, Text = "Flare Gun", ExpandHandle = "ModMenu_Shotgun_Ex", GetFunc = function() return _G.BNTMODConfig.Weapon_Flare end, SetFunc = function(c,v) _G.BNTMODConfig.Weapon_Flare = v _G.WeaponCache = {} return true end },
            { Key = "ModMenu_Vehicle_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ VEHICLES & OTHERS", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.EspVehicleCategory or false end, SetFunc = function(c,v) _G.BNTMODConfig.EspVehicleCategory = v return true end },
            { Key = "ModMenu_Veh_MiradoOrange", UI = AliasMap.Switcher, Text = "Mirado", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_MiradoOrange end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_MiradoOrange = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_MiradoRed", UI = AliasMap.Switcher, Text = "Mirado (RED)", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_MiradoRed end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_MiradoRed = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_Dacia", UI = AliasMap.Switcher, Text = "Dacia", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_Dacia end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_Dacia = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_Buggy", UI = AliasMap.Switcher, Text = "Buggy", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_Buggy end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_Buggy = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_UAZ_Old", UI = AliasMap.Switcher, Text = "Old Sedan / Coupe", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_UAZ_Old end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_UAZ_Old = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_Motorcycle", UI = AliasMap.Switcher, Text = "Motorcycle", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_Motorcycle end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_Motorcycle = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_Helicopter", UI = AliasMap.Switcher, Text = "Helicopter / Plane", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_Helicopter end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_Helicopter = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_BRDM", UI = AliasMap.Switcher, Text = "BRDM-2", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_BRDM end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_BRDM = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_Minibus", UI = AliasMap.Switcher, Text = "Minibus", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_Minibus end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_Minibus = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_MonsterTruck", UI = AliasMap.Switcher, Text = "Monster Truck", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_MonsterTruck end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_MonsterTruck = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_UAZ", UI = AliasMap.Switcher, Text = "UAZ (Jeep)", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_UAZ end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_UAZ = v _G.VehicleCache = {} return true end },
            { Key = "ModMenu_Veh_Pickup", UI = AliasMap.Switcher, Text = "Pickup / Rony", ExpandHandle = "ModMenu_Vehicle_Ex", GetFunc = function() return _G.BNTMODConfig.Veh_Pickup end, SetFunc = function(c,v) _G.BNTMODConfig.Veh_Pickup = v _G.VehicleCache = {} return true end },
        }

        local StackAimbotForce = {
            { Key = "ModMenu_AT_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ UR/SCRIM PLAYER - TOUCH AIM", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.AimTouchEnable end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchEnable = v return true end },
            { Key = "ModMenu_AT_Hip_Ex", UI = AliasMap.TitleSwitcher, Text = "   ▶ Hipfire Aimbot", ExpandHandle = "ModMenu_AT_Ex", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.AimTouchHipfire end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchHipfire = v return true end },
            { Key = "ModMenu_AT_Hip_IgKnock", UI = AliasMap.Switcher, Text = "      Ignore Knocked Enemies", ExpandHandle = "ModMenu_AT_Hip_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchHipIgKnock end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchHipIgKnock = v return true end },
            { Key = "ModMenu_AT_Hip_IgBot", UI = AliasMap.Switcher, Text = "      Ignore Bots", ExpandHandle = "ModMenu_AT_Hip_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchHipIgBot end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchHipIgBot = v return true end },
            { Key = "ModMenu_AT_Hip_Vis", UI = AliasMap.Switcher, Text = "      Visibility Check", ExpandHandle = "ModMenu_AT_Hip_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchHipVisCheck end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchHipVisCheck = v return true end },
            { Key = "ModMenu_AT_Hip_Prio", UI = AliasMap.Slider, Text = "      Aim Target", ExpandHandle = "ModMenu_AT_Hip_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchHipPrio or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchHipPrio = val return true end },
            { Key = "ModMenu_AT_Hip_Bone", UI = AliasMap.Slider, Text = "      Bone Target", ExpandHandle = "ModMenu_AT_Hip_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchHipBone or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchHipBone = val return true end },
            { Key = "ModMenu_AT_Hip_Cond", UI = AliasMap.Slider, Text = "      Condition", ExpandHandle = "ModMenu_AT_Hip_Ex", MinValue = 1, MaxValue = 2, min = 1, max = 2, Min = 1, Max = 2, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchHipCond or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 2 then val = 2 end; _G.BNTMODState.CustomTextData.AimTouchHipCond = val return true end },
            { Key = "ModMenu_AT_Hip_Spd", UI = AliasMap.Slider, Text = "      Aim / Speed Smooth", ExpandHandle = "ModMenu_AT_Hip_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchHipSpeed or 50 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchHipSpeed = v return true end },
            { Key = "ModMenu_AT_Hip_FOV", UI = AliasMap.Slider, Text = "      FOV Range", ExpandHandle = "ModMenu_AT_Hip_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchHipFOV or 30 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchHipFOV = v return true end },
            { Key = "ModMenu_AT_Hip_Dist", UI = AliasMap.Slider, Text = "      Distance", ExpandHandle = "ModMenu_AT_Hip_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return math.floor((_G.BNTMODState.CustomTextData.AimTouchHipDist or 250) / 5) end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchHipDist = v * 5 return true end },
            { Key = "ModMenu_AT_ScopeAll_Ex", UI = AliasMap.TitleSwitcher, Text = "   ▶ Scoped Aimbot (All Weapons)", ExpandHandle = "ModMenu_AT_Ex", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.AimTouchScopeAll end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchScopeAll = v return true end },
            { Key = "ModMenu_AT_ScopeAll_IgKnock", UI = AliasMap.Switcher, Text = "      Ignore Knocked Enemies", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchScopeIgKnock end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchScopeIgKnock = v return true end },
            { Key = "ModMenu_AT_ScopeAll_IgBot", UI = AliasMap.Switcher, Text = "      Ignore Bots", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchScopeIgBot end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchScopeIgBot = v return true end },
            { Key = "ModMenu_AT_ScopeAll_Vis", UI = AliasMap.Switcher, Text = "      Visibility Check", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchScopeVisCheck end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchScopeVisCheck = v return true end },
            { Key = "ModMenu_AT_ScopeAll_Prio", UI = AliasMap.Slider, Text = "      Scope Target", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopePrio or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchScopePrio = val return true end },
            { Key = "ModMenu_AT_ScopeAll_Bone", UI = AliasMap.Slider, Text = "      Bone Target", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopeBone or 2 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchScopeBone = val return true end },
            { Key = "ModMenu_AT_ScopeAll_Cond", UI = AliasMap.Slider, Text = "      Condition", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 1, MaxValue = 2, min = 1, max = 2, Min = 1, Max = 2, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopeCond or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 2 then val = 2 end; _G.BNTMODState.CustomTextData.AimTouchScopeCond = val return true end },
            { Key = "ModMenu_AT_ScopeAll_Spd", UI = AliasMap.Slider, Text = "      Scope Aim Speed", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopeSpeed or 40 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchScopeSpeed = v return true end },
            { Key = "ModMenu_AT_ScopeAll_FOV", UI = AliasMap.Slider, Text = "      FOV Range", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopeFOV or 20 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchScopeFOV = v return true end },
            { Key = "ModMenu_AT_ScopeAll_Dist", UI = AliasMap.Slider, Text = "      Distance", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return math.floor((_G.BNTMODState.CustomTextData.AimTouchScopeDist or 300) / 5) end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchScopeDist = v * 5 return true end },
            { Key = "ModMenu_AT_ScopeAll_Pred", UI = AliasMap.Slider, Text = "      Movement Prediction", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 0, MaxValue = 100, min = 0, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopePred or 0 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchScopePred = v return true end },
            { Key = "ModMenu_AT_ScopeAll_Recoil", UI = AliasMap.Slider, Text = "      Auto Recoil Compensation", ExpandHandle = "ModMenu_AT_ScopeAll_Ex", MinValue = 0, MaxValue = 50, min = 0, max = 50, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchScopeRecoil or 0 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchScopeRecoil = v return true end },
            { Key = "ModMenu_AT_SG_Ex", UI = AliasMap.TitleSwitcher, Text = "   ▶ Shotgun Aimbot", ExpandHandle = "ModMenu_AT_Ex", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.AimTouchSG end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSG = v return true end },
            { Key = "ModMenu_AT_SG_AutoFire", UI = AliasMap.Switcher, Text = "      Auto Fire", ExpandHandle = "ModMenu_AT_SG_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSGAutoFire end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSGAutoFire = v return true end },
            { Key = "ModMenu_AT_SG_IgKnock", UI = AliasMap.Switcher, Text = "      Ignore Knocked Enemies", ExpandHandle = "ModMenu_AT_SG_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSGIgKnock end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSGIgKnock = v return true end },
            { Key = "ModMenu_AT_SG_IgBot", UI = AliasMap.Switcher, Text = "      Ignore Bots", ExpandHandle = "ModMenu_AT_SG_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSGIgBot end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSGIgBot = v return true end },
            { Key = "ModMenu_AT_SG_Vis", UI = AliasMap.Switcher, Text = "      Visibility Check", ExpandHandle = "ModMenu_AT_SG_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSGVisCheck end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSGVisCheck = v return true end },
            { Key = "ModMenu_AT_SG_Prio", UI = AliasMap.Slider, Text = "      Priority", ExpandHandle = "ModMenu_AT_SG_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSGPrio or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchSGPrio = val return true end },
            { Key = "ModMenu_AT_SG_Bone", UI = AliasMap.Slider, Text = "      Bone Target", ExpandHandle = "ModMenu_AT_SG_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSGBone or 2 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchSGBone = val return true end },
            { Key = "ModMenu_AT_SG_Cond", UI = AliasMap.Slider, Text = "      Condition", ExpandHandle = "ModMenu_AT_SG_Ex", MinValue = 1, MaxValue = 2, min = 1, max = 2, Min = 1, Max = 2, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSGCond or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 2 then val = 2 end; _G.BNTMODState.CustomTextData.AimTouchSGCond = val return true end },
            { Key = "ModMenu_AT_SG_Spd", UI = AliasMap.Slider, Text = "      Smoothing / Speed", ExpandHandle = "ModMenu_AT_SG_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSGSpeed or 80 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSGSpeed = v return true end },
            { Key = "ModMenu_AT_SG_FOV", UI = AliasMap.Slider, Text = "      FOV Range", ExpandHandle = "ModMenu_AT_SG_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSGFOV or 40 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSGFOV = v return true end },
            { Key = "ModMenu_AT_SG_Dist", UI = AliasMap.Slider, Text = "      Distance", ExpandHandle = "ModMenu_AT_SG_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSGDist or 30 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSGDist = v return true end },
            { Key = "ModMenu_AT_Sniper_Ex", UI = AliasMap.TitleSwitcher, Text = "   ▶ Scoped Aimbot (Sniper Only)", ExpandHandle = "ModMenu_AT_Ex", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.AimTouchScopeSniper end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchScopeSniper = v return true end },
            { Key = "ModMenu_AT_Sniper_IgKnock", UI = AliasMap.Switcher, Text = "      Ignore Knocked Enemies", ExpandHandle = "ModMenu_AT_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSniperIgKnock end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSniperIgKnock = v return true end },
            { Key = "ModMenu_AT_Sniper_IgBot", UI = AliasMap.Switcher, Text = "      Ignore Bots", ExpandHandle = "ModMenu_AT_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSniperIgBot end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSniperIgBot = v return true end },
            { Key = "ModMenu_AT_Sniper_Vis", UI = AliasMap.Switcher, Text = "      Visibility Check", ExpandHandle = "ModMenu_AT_Sniper_Ex", GetFunc = function() return _G.BNTMODConfig.AimTouchSniperVisCheck end, SetFunc = function(c,v) _G.BNTMODConfig.AimTouchSniperVisCheck = v return true end },
            { Key = "ModMenu_AT_Sniper_Prio", UI = AliasMap.Slider, Text = "      Priority", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSniperPrio or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchSniperPrio = val return true end },
            { Key = "ModMenu_AT_Sniper_Bone", UI = AliasMap.Slider, Text = "      Bone Target", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 1, MaxValue = 4, min = 1, max = 4, Min = 1, Max = 4, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSniperBone or 1 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 4 then val = 4 end; _G.BNTMODState.CustomTextData.AimTouchSniperBone = val return true end },
            { Key = "ModMenu_AT_Sniper_Cond", UI = AliasMap.Slider, Text = "      Condition", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 1, MaxValue = 2, min = 1, max = 2, Min = 1, Max = 2, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSniperCond or 2 end, SetFunc = function(c,v) local val = math.floor(v+0.5); if val < 1 then val = 1 end; if val > 2 then val = 2 end; _G.BNTMODState.CustomTextData.AimTouchSniperCond = val return true end },
            { Key = "ModMenu_AT_Sniper_Spd", UI = AliasMap.Slider, Text = "      Smoothing / Speed", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSniperSpeed or 30 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSniperSpeed = v return true end },
            { Key = "ModMenu_AT_Sniper_FOV", UI = AliasMap.Slider, Text = "      FOV Range", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSniperFOV or 20 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSniperFOV = v return true end },
            { Key = "ModMenu_AT_Sniper_Dist", UI = AliasMap.Slider, Text = "      Distance", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return math.floor((_G.BNTMODState.CustomTextData.AimTouchSniperDist or 400) / 5) end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSniperDist = v * 5 return true end },
            { Key = "ModMenu_AT_Sniper_Pred", UI = AliasMap.Slider, Text = "      Movement Prediction", ExpandHandle = "ModMenu_AT_Sniper_Ex", MinValue = 0, MaxValue = 100, min = 0, max = 100, GetFunc = function() return _G.BNTMODState.CustomTextData.AimTouchSniperPred or 0 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.AimTouchSniperPred = v return true end },
            { Key = "ModMenu_Crosshair_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ SMALL CROSSHAIR", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.Crosshair end, SetFunc = function(c,v) _G.BNTMODConfig.Crosshair = v return true end },
            { Key = "ModMenu_Accuracy", UI = AliasMap.TitleSwitcher, Text = "▶ Straight-Flying Bullet", GetFunc = function() return _G.BNTMODConfig.Accuracy end, SetFunc = function(c,v) _G.BNTMODConfig.Accuracy = v return true end },
            { Key = "ModMenu_Mortar_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ MORTAR AIMBOT", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.MortarAim end, SetFunc = function(c,v) _G.BNTMODConfig.MortarAim = v return true end },
            { Key = "ModMenu_MortarDist", UI = AliasMap.Slider, Text = "      • Max Distance (Meters)", Min = 100, Max = 1000, Step = 50, ExpandHandle = "ModMenu_Mortar_Ex", GetFunc = function() return _G.BNTMODState.CustomTextData.MortarDist end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.MortarDist = v return true end },
            { Key = "ModMenu_MortarFOV", UI = AliasMap.Slider, Text = "      • FOV Range", Min = 10, Max = 180, Step = 5, ExpandHandle = "ModMenu_Mortar_Ex", GetFunc = function() return _G.BNTMODState.CustomTextData.MortarFOV end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.MortarFOV = v return true end },
            { Key = "ModMenu_MortarSpeed", UI = AliasMap.Slider, Text = "      • Aim Speed", Min = 10, Max = 100, Step = 5, ExpandHandle = "ModMenu_Mortar_Ex", GetFunc = function() return _G.BNTMODState.CustomTextData.MortarSpeed end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.MortarSpeed = v return true end }
        }

        local StackCombatGraphic = {
            { Key = "ModMenu_Ipad_Ex", UI = AliasMap.TitleSwitcher, Text = "▶ iPad View", ExpandIndex = 0, GetFunc = function() return _G.BNTMODConfig.IpadView end, SetFunc = function(c,v) _G.BNTMODConfig.IpadView = v return true end },
            { Key = "ModMenu_Ipad_FOV", UI = AliasMap.Slider, Text = "   FOV Angle", ExpandHandle = "ModMenu_Ipad_Ex", MinValue = 1, MaxValue = 100, min = 1, max = 100, GetFunc = function() return (_G.BNTMODState.CustomTextData.IpadViewFOV or 120) - 80 end, SetFunc = function(c,v) _G.BNTMODState.CustomTextData.IpadViewFOV = 80 + v return true end },
            { Key = "ModMenu_165FPS", UI = AliasMap.TitleSwitcher, Text = "▶ Unlock 165 FPS", GetFunc = function() return _G.BNTMODConfig.UnlockFPS end, SetFunc = function(c,v) _G.BNTMODConfig.UnlockFPS = v; if v then _G.BNTMODState.GraphicsUnlocked = false end return true end },
            -- ColorBodyNew (Wall & Color Purple/Yellow)
            { Key = "ModMenu_ColorBodyNew", UI = AliasMap.TitleSwitcher, Text = "▶ Wall & Color (Purple/Yellow)", GetFunc = function() return _G.BNTMODConfig.ColorBodyNew end, SetFunc = function(c,v) _G.BNTMODConfig.ColorBodyNew = v return true end },
            -- WhiteBody REMOVED
            { Key = "ModMenu_BlackSky", UI = AliasMap.TitleSwitcher, Text = "▶ Black Sky", GetFunc = function() return _G.BNTMODConfig.BlackSky end, SetFunc = function(c,v) _G.BNTMODConfig.BlackSky = v return true end },
            { Key = "ModMenu_RemoveGrass", UI = AliasMap.TitleSwitcher, Text = "▶ Remove Grass", GetFunc = function() return _G.BNTMODConfig.RemoveGrass end, SetFunc = function(c,v) _G.BNTMODConfig.RemoveGrass = v return true end },
            { Key = "ModMenu_RemoveTrees", UI = AliasMap.TitleSwitcher, Text = "▶ Remove Trees", GetFunc = function() return _G.BNTMODConfig.RemoveTrees end, SetFunc = function(c,v) _G.BNTMODConfig.RemoveTrees = v return true end },               
        }

        SettingPageDefine.ModMenu = {
        Key = "ModMenu",
        Text= "GFEyollo MENU",
        UIKey = "Setting_Page_Privacy", 
        Category = {
            { Key = "Cat_ESP_ITEAM", Text= "ESP & ITEAM", Stack = StackIteam },
            { Key = "Cat_Aimbot_Force", Text= "UR/ROOM-TOUCH AIM", Stack = StackAimbotForce },
            { Key = "Cat_Combat_Graphic", Text= "WALLHACK/FPS", Stack = StackCombatGraphic },
        }
    }
        
    table.insert(SettingCatalog, 1, SettingPageDefine.ModMenu)
end

    local UIManager = _G.UIManager
    if UIManager and not UIManager._IsModMenuHooked then
        local old_ShowUI = UIManager.ShowUI
        UIManager.ShowUI = function(config, ...)
            local args = {...}
            local n = select('#', ...) 
            if config and config.keyName and (string.find(string.lower(config.keyName), "setting_main") or string.find(string.lower(config.keyName), "setting")) then
                local catalog = args[1]
                if type(catalog) == "table" then
                    local hasModMenu = false
                    for _, page in ipairs(catalog) do
                        if type(page) == "table" and page.Key == "ModMenu" then hasModMenu = true; break end
                    end
                    if not hasModMenu then table.insert(catalog, 1, SettingPageDefine.ModMenu) end
                end
            end
            local table_unpack = table.unpack or unpack
            return old_ShowUI(config, table_unpack(args, 1, n))
        end
        UIManager._IsModMenuHooked = true
    end
end

local function ShowBNTMODVIPMenu() 
    if _G.BNTMODMenuAlreadyShown then return end
    if _G.BNTMODState.MenuStep ~= 0 then return end
    pcall(function()
        local Msg = require("client.slua.logic.common.logic_common_msg_box")
        if not Msg or not Msg.Show then return end
        local function Step_ScamAlert()
            Msg.Show(1, "4.7 RESELLER ACCEPT", "DON'T PLAY LIKE A CHEATER \nAVOID FROM REPORT!!\n\nNO FEEDBACK - NO SECURE UPDATE", function() local Web = require("client.slua.logic.url.logic_webview_sdk"); if Web and Web.OpenURL then Web:OpenURL("https://t.me/GFEyollo") end end, function() end, "JOIN", "CLOSE")
            _G.BNTMODState.MenuStep = 99
            _G.BNTMODMenuAlreadyShown = true
        end
        local function Step_Welcome()
            Msg.Show(1, "4.7 RESELLER ACCEPT", "ACTIVATION SUCCESSFUL!\n\nBEWARE OF THE SCAMMER CHECK THE USERNAME.\nTHE REAL OWNER IS @GFEyollo",
            function() _G.InitModMenuTab(); Notify("VIP MOD MENU BY @GFEyollo to toggle features!"); Step_ScamAlert() end, 
            function() end, "OK", "CLOSE")
        end
        _G.BNTMODState.MenuStep = 1
        Step_Welcome() 
    end)
end

local function InitializeGraphicsUnlock() 
    if isExpired then return end
    if _G.BNTMODState.GraphicsUnlocked or currentTime > limitTime then return end
    pcall(function()
        local SettingCfg = require("client.logic.setting.setting_config")
        local GraphicSettingDB = require("client.slua.umg.NewSetting.GraphicsNew.GraphicSettingDB")
        if SettingCfg then
            if SettingCfg.TpViewValue then SettingCfg.TpViewValue.max = 160 end
            if SettingCfg.FpViewValue then SettingCfg.FpViewValue.max = 160 end
        end
        if GraphicSettingDB then
            if GraphicSettingDB.TpViewValue then GraphicSettingDB.TpViewValue.max = 160 end
        end
    end)
    pcall(function()
        local logic_setting_graphics = require("client.slua.logic.setting.logic_setting_graphics")
        local GSC_FPS = require("client.slua.umg.NewSetting.GraphicsNew.Comps.GSC_FPS")
        local GraphicSettingDB = require("client.slua.umg.NewSetting.GraphicsNew.GraphicSettingDB")
        if logic_setting_graphics then
            local old_SetFPS = logic_setting_graphics.SetFPS
            function logic_setting_graphics.SetFPS(gameInstance, FPSLevel)
                if old_SetFPS then old_SetFPS(gameInstance, FPSLevel) end
                if FPSLevel == 8 then 
                    gameInstance:ExecuteCMD("t.MaxFPS", "165")
                    gameInstance:ExecuteCMD("r.FrameRateLimit", "165")
                end
            end
        end
        if GSC_FPS and GSC_FPS.__inner_impl then
            local fps_impl = GSC_FPS.__inner_impl
            function fps_impl:GetMaxFPSLevel() return 8, 8 end
            function fps_impl:InitRealSupportFPS()
                local RealSupportFPS = {}
                for i = 1, 8 do RealSupportFPS[i] = {true, true} end
                if GraphicSettingDB then GraphicSettingDB:UpdateUIData(GraphicSettingDB.RealSupportFPS, RealSupportFPS, false) end
                return RealSupportFPS
            end
        end
    end)
    _G.BNTMODState.GraphicsUnlocked = true
    Notify("Graphics & FPS 165Hz Unlocked")
end

local function InitializeNativeESP() 
    if _G.BNTMODState.NativeESPReady then return end
    pcall(function() 
        local GamePlayTools = require("GameLua.Mod.BaseMod.Common.GamePlayTools") 
        local currentMarkCfg = GamePlayTools.GetCurrentConfig("ScreenMarkConfig") 
        local function ApplyCfg(cfg)
            if not cfg then return end 
            if cfg[1006] then 
                cfg[1006].bBindBlocked = true; cfg[1006].bBindOutScreen = true; 
                cfg[1006].MaxWidgetNum = 99; cfg[1006].MaxShowDistance = 6000000; 
                cfg[1006].bScaleByDistance = false; cfg[1006].BindSocketName = "root"; 
                cfg[1006].bUseLuaWorldSocketName = true; cfg[1006].WorldPositionOffset = FVector(0, 0, -30) 
            end 
            cfg[8888] = { 
                UIPathName = "/Game/Mod/EvoBase/BluePrints/UIBP/QuickSign/QuickSign_TipHitEnemy_UIBP_New.QuickSign_TipHitEnemy_UIBP_New_C",
                MaxWidgetNum = 99, MaxShowDistance = 6000000, bBindOutScreen = true, bBindBlocked = true, 
                bIsBindingActor = true, BindSocketName = "head", bUseLuaWorldSocketName = true, 
                WorldPositionOffset = FVector(0, 0, 30), bNeedPreLoad = true, Priority = 2 
            } 
            cfg[9999] = { 
                UIPathName = "/Game/Mod/EvoBase/BluePrints/UIBP/QuickSign/QuickSign_TipHitEnemy_UIBP_New.QuickSign_TipHitEnemy_UIBP_New_C",
                MaxWidgetNum = 99, MaxShowDistance = 6000000, bBindOutScreen = true, bBindBlocked = true, 
                bIsBindingActor = true, BindSocketName = "head", bUseLuaWorldSocketName = true, 
                WorldPositionOffset = FVector(0, 0, 50), bNeedPreLoad = true, Priority = 2 
            } 
        end 
        ApplyCfg(currentMarkCfg) 
        for k, cfg in pairs(package.loaded) do 
            if type(k) == "string" and string.find(k, "ScreenMarkConfig") and type(cfg) == "table" then ApplyCfg(cfg) end 
        end 
    end)
    _G.BNTMODState.NativeESPReady = true 
    Notify("Native ESP System Initialized") 
end

local function GetAllSkeletalMeshes(enemy, markData)
    local curTime = os.clock()
    if markData and markData.CachedMeshes and markData.CachedMeshTime and (curTime - markData.CachedMeshTime) < MESH_CACHE_TIME then
        local validMeshes = {}
        for _, cachedMesh in ipairs(markData.CachedMeshes) do
            if Valid(cachedMesh) then table.insert(validMeshes, cachedMesh) end
        end
        markData.CachedMeshes = validMeshes
        return validMeshes
    end
    local meshes = {}
    if Valid(enemy.Mesh) then table.insert(meshes, enemy.Mesh) end
    pcall(function()
        local SkeletalMeshClass = import("SkeletalMeshComponent")
        if SkeletalMeshClass and type(enemy.GetComponentsByClass) == "function" then
            local childs = enemy:GetComponentsByClass(SkeletalMeshClass)
            if childs then
                local count = type(childs.Num) == "function" and childs:Num() or #childs
                for i = 1, count do
                    local comp = type(childs.Get) == "function" and childs:Get(i-1) or childs[i]
                    if Valid(comp) and comp ~= enemy.Mesh then table.insert(meshes, comp) end
                end
            end
        end
    end)
    if markData then
        markData.CachedMeshes = meshes
        markData.CachedMeshTime = curTime
    end
    return meshes
end

-- ========================================== 
-- COLOR BODY NEW (Wall & Color Purple/Yellow)
-- ========================================== 
local function ApplyColorBodyNew(enemy, markData)
    pcall(function()
        -- Kích hoạt Console Command nếu chưa bật (Chỉ gọi 1 lần)
        if not _G.ConsoleNewWallReady then
            local KismetSystemLibrary = import("KismetSystemLibrary")
            local world = slua.getWorld()
            if KismetSystemLibrary and world then
                KismetSystemLibrary.ExecuteConsoleCommand(world, "r.EnableDrawDyeingColor 1")
                KismetSystemLibrary.ExecuteConsoleCommand(world, "r.CustomDepth 3")
                KismetSystemLibrary.ExecuteConsoleCommand(world, "r.IdeaOutline.Enable 1")
                KismetSystemLibrary.ExecuteConsoleCommand(world, "r.Highlight.Enable 1")
                _G.ConsoleNewWallReady = true
            end
        end

        -- Lấy toàn bộ Mesh của kẻ địch
        local meshes = GetAllSkeletalMeshes(enemy, markData)
        
        -- Thêm lưới của vũ khí đang cầm trên tay
        local weapon = nil
        pcall(function() weapon = enemy:GetCurrentWeapon() end)
        if slua.isValid(weapon) and slua.isValid(weapon.Mesh) then
            table.insert(meshes, weapon.Mesh)
        end

        local isBot = markData.AK_IS_BOT or false
        local currentMeshCount = #meshes
        
        -- [TỐI ƯU FPS TUYỆT ĐỐI] - CHẾ ĐỘ NGỦ ĐÔNG (CACHE)
        -- Tạo mã băm nhận diện: Nếu số lượng quần áo/súng của địch không đổi, bỏ qua vòng lặp C++ cực nặng bên dưới
        local stateHash = (isBot and "BOT" or "PLAYER") .. "_" .. tostring(currentMeshCount)
        
        if markData.LastColorNewHash == stateHash and markData.ColorNewApplied then
            return -- Mọi thứ đã được tô màu trước đó, ngắt hàm tại đây để tránh đốt CPU!
        end
        
        -- Nếu có sự thay đổi (mới bật, địch đổi súng, lụm đồ), tiến hành cập nhật màu và lưu Cache
        markData.LastColorNewHash = stateHash
        markData.ColorNewApplied = true

        -- Chỉ Load bộ màu khi thực sự cần xử lý
        local LinearColorClass = import("LinearColor") or _G.FLinearColor
        local c_vis = LinearColorClass and LinearColorClass(0, 100, 0, 1) or {R=0, G=100, B=0, A=1}
        local c_occ = LinearColorClass and LinearColorClass(100, 0, 0, 1) or {R=100, G=0, B=0, A=1}
        local c_bVis = LinearColorClass and LinearColorClass(49, 48, 0, 100) or {R=49, G=48, B=0, A=100}
        local c_bOcc = LinearColorClass and LinearColorClass(9, 1.5, 45, 100) or {R=9, G=1.5, B=45, A=100}

        local visColor = isBot and c_bVis or c_vis
        local occColor = isBot and c_bOcc or c_occ

        for _, mesh in ipairs(meshes) do
            if Valid(mesh) then
                pcall(function()
                    if type(mesh.SetDrawDyeing) == "function" then
                        mesh:SetDrawDyeing(true)
                        mesh:SetDrawDyeingMode(1)
                        mesh:SetVisibleDyeingColor(visColor)
                        mesh:SetOccludedDyeingColor(occColor)
                        mesh:SetDyeingColorFadeDistance(99999.0)
                        mesh:SetDyeingColorMinMaxDistance(0.0, 99999.0)
                        mesh:SetDrawHighlight(true)
                        mesh:OverrideHighlightColor(visColor)
                        mesh:SetHighlightCanBeOccluded(false)
                        mesh:SetDrawIdeaOutline(true)
                        mesh:SetIdeaOutlineNew(true)
                        mesh:SetIdeaOutlineOcclusionHighlight(true)
                        mesh:OverrideIdeaOutlineColor(visColor)
                        mesh:SetIdeaOutlineOcclusionColor(occColor)
                        mesh:OverrideIdeaOutlineThickness(20.0)
                        mesh:SetIdeaOverrideOutlineAndOcclusion(true)
                        mesh:SetRenderCustomDepth(true)
                        mesh:SetCustomDepthStencilValue(255)
                    end
                end)
            end
        end
    end)
end

local function UndoColorBodyNew(enemy, markData)
    pcall(function()
        if markData.ColorNewApplied then
            local meshes = GetAllSkeletalMeshes(enemy, markData)
            local weapon = nil
            pcall(function() weapon = enemy:GetCurrentWeapon() end)
            if slua.isValid(weapon) and slua.isValid(weapon.Mesh) then
                table.insert(meshes, weapon.Mesh)
            end

            for _, mesh in ipairs(meshes) do
                if Valid(mesh) then
                    pcall(function()
                        if type(mesh.SetDrawDyeing) == "function" then
                            mesh:SetDrawDyeing(false)
                            mesh:SetDrawHighlight(false)
                            mesh:SetDrawIdeaOutline(false)
                            mesh:SetRenderCustomDepth(false)
                        end
                    end)
                end
            end
            markData.ColorNewApplied = false
            markData.LastColorNewHash = "" -- Xóa Cache để lần sau bật lại sẽ tính toán lại mượt mà
        end
    end)
end


-- ========================================== 
-- AIMBOT SYSTEM
-- ========================================== 
_G.GetEnemyTargetsFromActors = function(radius)
    local result = {}
    local player = GameplayData.GetPlayerCharacter()
    if not slua.isValid(player) then return result end
    local allCharacters = {}
    if GameplayData.GetAllPlayerCharacters then
        allCharacters = GameplayData.GetAllPlayerCharacters()
    elseif GameplayData.GameCharacters then
        for _, char in pairs(GameplayData.GameCharacters) do table.insert(allCharacters, char) end
    end
    local myTeam = player:GetTeamID()
    for _, actor in pairs(allCharacters) do
        if slua.isValid(actor) and actor ~= player and actor.GetTeamID and actor:IsAlive() then
            if actor:GetTeamID() ~= myTeam then
                local dist = player:GetDistanceTo(actor)
                if dist <= radius then table.insert(result, actor) end
            end
        end
    end
    return result
end

_G.AimTouch = function()
    pcall(function()
        if not _G.BNTMODConfig.AimTouchEnable then return end
        local player = GameplayData.GetPlayerCharacter()
        if not slua.isValid(player) then return end
        local pc = player:GetPlayerControllerSafety()
        if not slua.isValid(pc) then return end
        local isFiring = player.bIsWeaponFiring
        local isADS = player.bIsGunADS
        local weapon = player.WeaponManagerComponent and player.WeaponManagerComponent.CurrentWeaponReplicated
        if not weapon and type(player.GetCurrentShootWeapon) == "function" then weapon = player:GetCurrentShootWeapon() end
        
        local isShotgun = false
        local isSniper = false
        local currentAmmo = 1
        
        if slua.isValid(weapon) then
            local wID = type(weapon.GetWeaponID) == "function" and weapon:GetWeaponID() or 0
            local wName = type(weapon.GetWeaponName) == "function" and weapon:GetWeaponName() or ""
            if (wID >= 1030000 and wID < 1040000) or wName:find("S686") or wName:find("S1897") or wName:find("S12") or wName:find("DBS") or wName:find("M1014") then isShotgun = true end
            if wName:find("Kar98") or wName:find("M24") or wName:find("AWM") or wName:find("Mosin") or wName:find("Win94") or wName:find("AMR") or wName:find("SKS") or wName:find("SLR") or wName:find("Mini") or wName:find("Mk14") or wName:find("QBU") or wName:find("Mk12") or wName:find("VSS") then isSniper = true end
            if type(weapon.GetCurrentAmmo) == "function" then currentAmmo = weapon:GetCurrentAmmo()
            elseif weapon.ShootWeaponComponent and type(weapon.ShootWeaponComponent.GetCurrentAmmo) == "function" then currentAmmo = weapon.ShootWeaponComponent:GetCurrentAmmo()
            elseif weapon.CurrentAmmo ~= nil then currentAmmo = weapon.CurrentAmmo end
        end

        if _G.BNTMODState.IsAutoFiring then
            pcall(function()
                player.bIsWeaponFiring = false
                if type(player.SetIsWeaponFiring) == "function" then player:SetIsWeaponFiring(false) end
                if slua.isValid(pc) and type(pc.SetIsWeaponFiring) == "function" then pc:SetIsWeaponFiring(false) end
                local wepMgr = player.WeaponManagerComponent
                if slua.isValid(wepMgr) then wepMgr.bIsWeaponFiring = false end
            end)
            _G.BNTMODState.IsAutoFiring = false
        end

        if isShotgun and currentAmmo <= 0 then return end

        local cond = 2
        local prioMode = 1
        local boneIdx = 1
        local speedVal = 50
        local fovVal = 30
        local maxDistMeters = 50
        local useVisCheck = false
        local igKnock = false
        local igBot = false
        local predVal = 0 
        local recoilCompVal = 0 

        if isShotgun and _G.BNTMODConfig.AimTouchSG then
            cond = _G.BNTMODState.CustomTextData.AimTouchSGCond or 1
            if _G.BNTMODConfig.AimTouchSGAutoFire then cond = 2 end
            if cond == 1 and not isFiring then return end
            prioMode = _G.BNTMODState.CustomTextData.AimTouchSGPrio or 1
            boneIdx = _G.BNTMODState.CustomTextData.AimTouchSGBone or 2
            speedVal = _G.BNTMODState.CustomTextData.AimTouchSGSpeed or 80
            fovVal = _G.BNTMODState.CustomTextData.AimTouchSGFOV or 40
            maxDistMeters = _G.BNTMODState.CustomTextData.AimTouchSGDist or 30
            useVisCheck = _G.BNTMODConfig.AimTouchSGVisCheck
            igKnock = _G.BNTMODConfig.AimTouchSGIgKnock
            igBot = _G.BNTMODConfig.AimTouchSGIgBot
        elseif isADS then
            if isSniper and _G.BNTMODConfig.AimTouchScopeSniper then
                cond = _G.BNTMODState.CustomTextData.AimTouchSniperCond or 2
                if cond == 1 and not isFiring then return end
                prioMode = _G.BNTMODState.CustomTextData.AimTouchSniperPrio or 1
                boneIdx = _G.BNTMODState.CustomTextData.AimTouchSniperBone or 1
                speedVal = _G.BNTMODState.CustomTextData.AimTouchSniperSpeed or 30
                fovVal = _G.BNTMODState.CustomTextData.AimTouchSniperFOV or 20
                maxDistMeters = _G.BNTMODState.CustomTextData.AimTouchSniperDist or 400
                useVisCheck = _G.BNTMODConfig.AimTouchSniperVisCheck
                igKnock = _G.BNTMODConfig.AimTouchSniperIgKnock
                igBot = _G.BNTMODConfig.AimTouchSniperIgBot
                predVal = _G.BNTMODState.CustomTextData.AimTouchSniperPred or 0
            elseif _G.BNTMODConfig.AimTouchScopeAll then
                cond = _G.BNTMODState.CustomTextData.AimTouchScopeCond or 1
                if cond == 1 and not isFiring then return end
                prioMode = _G.BNTMODState.CustomTextData.AimTouchScopePrio or 1
                boneIdx = _G.BNTMODState.CustomTextData.AimTouchScopeBone or 2
                speedVal = _G.BNTMODState.CustomTextData.AimTouchScopeSpeed or 40
                fovVal = _G.BNTMODState.CustomTextData.AimTouchScopeFOV or 20
                maxDistMeters = _G.BNTMODState.CustomTextData.AimTouchScopeDist or 300
                useVisCheck = _G.BNTMODConfig.AimTouchScopeVisCheck
                igKnock = _G.BNTMODConfig.AimTouchScopeIgKnock
                igBot = _G.BNTMODConfig.AimTouchScopeIgBot
                predVal = _G.BNTMODState.CustomTextData.AimTouchScopePred or 0
                recoilCompVal = _G.BNTMODState.CustomTextData.AimTouchScopeRecoil or 0
            else return end
        else
            if not _G.BNTMODConfig.AimTouchHipfire then return end
            cond = _G.BNTMODState.CustomTextData.AimTouchHipCond or 1
            if cond == 1 and not isFiring then return end 
            prioMode = _G.BNTMODState.CustomTextData.AimTouchHipPrio or 1
            boneIdx = _G.BNTMODState.CustomTextData.AimTouchHipBone or 1
            speedVal = _G.BNTMODState.CustomTextData.AimTouchHipSpeed or 50
            fovVal = _G.BNTMODState.CustomTextData.AimTouchHipFOV or 30
            maxDistMeters = _G.BNTMODState.CustomTextData.AimTouchHipDist or 250
            useVisCheck = _G.BNTMODConfig.AimTouchHipVisCheck
            igKnock = _G.BNTMODConfig.AimTouchHipIgKnock
            igBot = _G.BNTMODConfig.AimTouchHipIgBot
        end

        local currentMaxDist = maxDistMeters * 100 
        local enemies = _G.GetEnemyTargetsFromActors(currentMaxDist)
        if not enemies or #enemies == 0 then return end
        
        local FVector2D = import("Vector2D")
        local UGameplayStatics = import("GameplayStatics")
        local KismetMathLibrary = import("KismetMathLibrary")
        
        local camManager = UGameplayStatics.GetPlayerCameraManager(pc, 0)
        if not slua.isValid(camManager) then return end
        local camLoc = camManager:GetCameraLocation()
        if not camLoc then return end
        
        local ui_util = require("client.common.ui_util")
        if not ui_util then return end
        local viewportSize = ui_util.GetViewportSize()
        if not viewportSize then return end
        
        local centerX = viewportSize.X * 0.5
        local centerY = viewportSize.Y * 0.5
        local FOV_RADIUS = (fovVal / 100.0) * (viewportSize.X / 2.0)
        
        local bestTarget = nil
        local bestScore = 99999999 
        
        local selBoneName = "head"
        if boneIdx == 1 then selBoneName = "head"
        elseif boneIdx == 2 then selBoneName = "spine_03"
        elseif boneIdx == 3 then selBoneName = "spine_01"
        elseif boneIdx == 4 then selBoneName = "pelvis" end

        for i, target in ipairs(enemies) do
            if not slua.isValid(target) then goto continue end
            if igKnock and target.HealthStatus == 1 then goto continue end
            if igBot then
                local tIsBot = false
                if target.bIsAI == true or target.IsAI == true then tIsBot = true end
                local pState = target.PlayerState
                if slua.isValid(pState) and (pState.bIsABot or pState.bIsBot) then tIsBot = true end
                if tIsBot then goto continue end
            end
            if useVisCheck then
                local curTime = os.clock()
                local tId = type(target.GetUniqueID) == "function" and target:GetUniqueID() or tostring(target)
                _G.AimTouchVisCache = _G.AimTouchVisCache or {}
                if not _G.AimTouchVisCache[tId] or (curTime - _G.AimTouchVisCache[tId].time) > 0.3 then
                    local isHidden = true
                    pcall(function() if pc:LineOfSightTo(target) then isHidden = false end end)
                    _G.AimTouchVisCache[tId] = { hidden = isHidden, time = curTime }
                end
                if _G.AimTouchVisCache[tId].hidden then goto continue end
            end
            local tPos = target:GetBonePos(selBoneName, {X=0, Y=0, Z=0})
            if not tPos or (tPos.X == 0 and tPos.Y == 0 and tPos.Z == 0) then
                if type(target.GetSocketLocation) == "function" then tPos = target:GetSocketLocation(selBoneName) end
            end
            if not tPos or (tPos.X == 0 and tPos.Y == 0 and tPos.Z == 0) then
                if type(target.K2_GetActorLocation) == "function" then
                    tPos = target:K2_GetActorLocation()
                    if tPos then
                        if boneIdx == 1 then tPos.Z = tPos.Z + 70
                        elseif boneIdx == 2 then tPos.Z = tPos.Z + 40
                        elseif boneIdx == 3 then tPos.Z = tPos.Z + 20 end
                    end
                end
            end
            if not tPos or (tPos.X == 0 and tPos.Y == 0 and tPos.Z == 0) then goto continue end
            local screen = FVector2D()
            local success = pc:ProjectWorldLocationToScreen(tPos, screen, false)
            if not success or screen.X <= 0 or screen.Y <= 0 then goto continue end
            local dx = screen.X - centerX
            local dy = screen.Y - centerY
            local distScreen = math.sqrt(dx*dx + dy*dy)
            if distScreen > FOV_RADIUS then goto continue end
            local currentScore = distScreen
            if prioMode == 2 then currentScore = player:GetDistanceTo(target)
            elseif prioMode == 3 then currentScore = target.Health or 100
            elseif prioMode == 4 then 
                local hp = target.Health or 100
                local maxhp = target.HealthMax or 100
                if maxhp <= 0 then maxhp = 100 end
                currentScore = hp / maxhp
            end
            if currentScore < bestScore then
                bestScore = currentScore
                bestTarget = target
            end
            ::continue::
        end
        
        if not slua.isValid(bestTarget) then return end
        
        local finalBonePos = bestTarget:GetBonePos(selBoneName, {X=0, Y=0, Z=0})
        if not finalBonePos or (finalBonePos.X == 0 and finalBonePos.Y == 0 and finalBonePos.Z == 0) then
            if type(bestTarget.GetSocketLocation) == "function" then finalBonePos = bestTarget:GetSocketLocation(selBoneName) end
        end
        if not finalBonePos or (finalBonePos.X == 0 and finalBonePos.Y == 0 and finalBonePos.Z == 0) then
            if type(bestTarget.K2_GetActorLocation) == "function" then
                finalBonePos = bestTarget:K2_GetActorLocation()
                if finalBonePos then
                    if boneIdx == 1 then finalBonePos.Z = finalBonePos.Z + 70
                    elseif boneIdx == 2 then finalBonePos.Z = finalBonePos.Z + 40
                    elseif boneIdx == 3 then finalBonePos.Z = finalBonePos.Z + 20 end
                end
            end
        end
        if not finalBonePos or (finalBonePos.X == 0 and finalBonePos.Y == 0 and finalBonePos.Z == 0) then return end
        
        if predVal > 0 then
            pcall(function()
                local tVelocity = nil
                if type(bestTarget.GetVelocity) == "function" then tVelocity = bestTarget:GetVelocity() end
                if tVelocity and (tVelocity.X ~= 0 or tVelocity.Y ~= 0) then
                    local distToEnemy = player:GetDistanceTo(bestTarget) / 100.0
                    local ToF = (distToEnemy / 800.0) * (predVal / 50.0) 
                    finalBonePos.X = finalBonePos.X + (tVelocity.X * ToF)
                    finalBonePos.Y = finalBonePos.Y + (tVelocity.Y * ToF)
                end
            end)
        end

        local rot = KismetMathLibrary.FindLookAtRotation(camLoc, finalBonePos)
        if not rot then return end
        local currentRot = pc:GetControlRotation()
        if not currentRot then return end
        local deltaYaw = rot.Yaw - currentRot.Yaw
        local deltaPitch = rot.Pitch - currentRot.Pitch
        if isADS then
            local camRot = nil
            if type(camManager.GetCameraRotation) == "function" then camRot = camManager:GetCameraRotation() end
            if camRot then
                deltaYaw = deltaYaw - (camRot.Yaw - currentRot.Yaw)
                deltaPitch = deltaPitch - (camRot.Pitch - currentRot.Pitch)
            end
        end
        if deltaYaw > 180 then deltaYaw = deltaYaw - 360 end
        if deltaYaw < -180 then deltaYaw = deltaYaw + 360 end
        if deltaPitch > 180 then deltaPitch = deltaPitch - 360 end
        if deltaPitch < -180 then deltaPitch = deltaPitch + 360 end
        local smoothFactor = 0.0
        if speedVal >= 100 then smoothFactor = 1.0
        else
            smoothFactor = (speedVal / 100.0) * 0.3
            if smoothFactor < 0.01 then smoothFactor = 0.01 end
        end
        local finalPitch = currentRot.Pitch + (deltaPitch * smoothFactor)
        local finalYaw = currentRot.Yaw + (deltaYaw * smoothFactor)
        if recoilCompVal > 0 and isFiring then
            local pullDownForce = (recoilCompVal / 50.0) * 1.5
            finalPitch = finalPitch - pullDownForce
        end
        local finalRot = { Pitch = finalPitch, Yaw = finalYaw, Roll = 0 }
        pc:SetControlRotation(finalRot, "AimTouch")
        
        if isShotgun and _G.BNTMODConfig.AimTouchSGAutoFire then
            pcall(function()
                local distToTarget = player:GetDistanceTo(bestTarget) / 100
                if distToTarget <= maxDistMeters then
                    player.bIsWeaponFiring = true
                    if type(player.SetIsWeaponFiring) == "function" then player:SetIsWeaponFiring(true) end
                    if slua.isValid(pc) and type(pc.SetIsWeaponFiring) == "function" then pc:SetIsWeaponFiring(true) end
                    local wepMgr = player.WeaponManagerComponent
                    if slua.isValid(wepMgr) then wepMgr.bIsWeaponFiring = true end
                    local currentWep = player:GetCurrentWeapon()
                    if slua.isValid(currentWep) and type(currentWep.StartFire) == "function" then currentWep:StartFire() end
                    _G.BNTMODState.IsAutoFiring = true
                end
            end)
        end
    end)
end

-- ========================================== 
-- MAIN LOOP
-- ========================================== 
local function MainLoop() 
    if isExpired then return end

    if _G.BNTMODState.CustomTextData == nil then 
        _G.BNTMODState.CustomTextData = {OuterSpeed = 10, InnerSpeed = 10, HRecoil = 0.3, VRecoil = 0.3, IpadViewFOV = 120, AimTouchHipPrio = 1, AimTouchHipBone = 1, AimTouchHipCond = 1, AimTouchHipSpeed = 50, AimTouchHipFOV = 30, AimTouchHipDist = 250, AimTouchSGPrio = 1, AimTouchSGBone = 2, AimTouchSGCond = 1, AimTouchSGSpeed = 80, AimTouchSGFOV = 40, AimTouchSGDist = 30, AimTouchScopePrio = 1, AimTouchScopeBone = 2, AimTouchScopeCond = 1, AimTouchScopeSpeed = 40, AimTouchScopeFOV = 20, AimTouchScopeDist = 300, AimTouchSniperPrio = 1, AimTouchSniperBone = 1, AimTouchSniperCond = 2, AimTouchSniperSpeed = 30, AimTouchSniperFOV = 20, AimTouchSniperDist = 400, MortarCond = 2, MortarSpeed = 2, MortarFOV = 2, MortarDist = 2}
    end

    local okData, GameplayData = pcall(require, "GameLua.GameCore.Data.GameplayData") 
    if not okData or not GameplayData then return end 
    local pc = GameplayData.GetPlayerController() 
    local localPlayer = nil
    if Valid(pc) then localPlayer = pc:GetPlayerCharacterSafety() end 

    if not Valid(localPlayer) then 
        if _G.BNTMODState.TrackedMarks then
            for markId, _ in pairs(_G.BNTMODState.TrackedMarks) do SafeRemoveMark(markId) end
        end
        _G.BNTMODState.TrackedMarks = {} 
        for key, data in pairs(_G.BNTMODState.EnemyMarks) do
            if data and data.MIDs then
                for meshStr, midTable in pairs(data.MIDs) do
                    for k, _ in pairs(midTable) do midTable[k] = nil end
                end
                data.MIDs = nil
            end
        end
        _G.BNTMODState.EnemyMarks = {}
        _G.BNTMODState.PrevGraphicsState = {}
        return 
    end

    local Cached_MyHUD = pc and pc.MyHUD or nil

    if _G.BNTMODConfig.UnlockFPS then InitializeGraphicsUnlock() end
    InitializeNativeESP()
    ShowBNTMODVIPMenu()
    
    if _G.BNTMODConfig.IpadView and _G.BNTMODState.CustomTextData then
        pcall(function()
            local targetTPP = _G.BNTMODState.CustomTextData.IpadViewFOV or 120
            local uTPPCam = localPlayer.ThirdPersonCameraComponent
            if Valid(uTPPCam) and not localPlayer.bIsWeaponAiming then
                if uTPPCam.FieldOfView ~= targetTPP then uTPPCam.FieldOfView = targetTPP end
            end
        end)
    else
        pcall(function()
            local uTPPCam = localPlayer.ThirdPersonCameraComponent
            if Valid(uTPPCam) and not localPlayer.bIsWeaponAiming then
                if uTPPCam.FieldOfView ~= 80 then uTPPCam.FieldOfView = 80 end
            end
        end)
    end

    pcall(function()
        if Valid(pc) then
            if pc.HiggsBoson then pc.HiggsBoson.bMHActive = false; pc.HiggsBoson.bCallPreReplication = false end
            if pc.HiggsBosonComponent then pc.HiggsBosonComponent.bMHActive = false; pc.HiggsBosonComponent.bCallPreReplication = false end
        end
    end)
           
    -- ========================================== 
    -- GRAPHICS: WhiteBody REMOVED, ColorBodyNew PRESENT
    -- ========================================== 
    pcall(function()
        local lsg = require("client.slua.logic.setting.logic_setting_graphics")
        local gi = lsg.GetGameInstance()
        if gi then
            if _G.BNTMODConfig.RemoveGrass and not _G.BNTMODState.PrevGraphicsState.RemoveGrass then
                gi:ExecuteCMD("grass.DensityScale", "0")
                gi:ExecuteCMD("grass.DiscardDataOnLoad", "1")
                _G.BNTMODState.PrevGraphicsState.RemoveGrass = true
            elseif not _G.BNTMODConfig.RemoveGrass and _G.BNTMODState.PrevGraphicsState.RemoveGrass then
                gi:ExecuteCMD("grass.DensityScale", "1")
                gi:ExecuteCMD("grass.DiscardDataOnLoad", "0")
                _G.BNTMODState.PrevGraphicsState.RemoveGrass = false
            end
            if _G.BNTMODConfig.RemoveTrees and not _G.BNTMODState.PrevGraphicsState.RemoveTrees then
                gi:ExecuteCMD("foliage.DensityScale", "0")
                gi:ExecuteCMD("r.Foliage.DensityScale", "0")
                gi:ExecuteCMD("foliage.MinimumScreenSize", "10000")
                gi:ExecuteCMD("r.DisableTreeRender", "1")
                _G.BNTMODState.PrevGraphicsState.RemoveTrees = true
            elseif not _G.BNTMODConfig.RemoveTrees and _G.BNTMODState.PrevGraphicsState.RemoveTrees then
                gi:ExecuteCMD("foliage.DensityScale", "1")
                gi:ExecuteCMD("r.Foliage.DensityScale", "1")
                gi:ExecuteCMD("foliage.MinimumScreenSize", "0.0001")
                gi:ExecuteCMD("r.DisableTreeRender", "0")
                _G.BNTMODState.PrevGraphicsState.RemoveTrees = false
            end            
            -- ColorBodyNew graphics setup (WhiteBody block REMOVED)
            if _G.BNTMODConfig.BlackSky and not _G.BNTMODState.PrevGraphicsState.BlackSky then
                gi:ExecuteCMD("r.CylinderMaxDrawHeight", "9999")
                _G.BNTMODState.PrevGraphicsState.BlackSky = true
            elseif not _G.BNTMODConfig.BlackSky and _G.BNTMODState.PrevGraphicsState.BlackSky then
                gi:ExecuteCMD("r.CylinderMaxDrawHeight", "0000")
                _G.BNTMODState.PrevGraphicsState.BlackSky = false
            end
        end
    end)

-- ============================================================
-- LUCKY EGG ESP SYSTEM
-- ============================================================
_G.RealNow = _G.RealNow or function() return os.clock() end
_G.LastScanLuckyEggTime = _G.LastScanLuckyEggTime or 0
_G.CachedLuckyEggs = _G.CachedLuckyEggs or {}
_G.LuckyEggESP_MaxLabels = _G.LuckyEggESP_MaxLabels or 40

local C_EGG = { R = 255, G = 165, B = 0, A = 255 }
local LuckyEggDatabase = {
    [2230001] = { name = "Lv. 1 Lucky Egg", color = C_EGG },
    [2230002] = { name = "Lv. 2 Lucky Egg", color = C_EGG },
    [2230003] = { name = "Lv. 3 Lucky Egg", color = C_EGG },
    [2230004] = { name = "Lv. 4 Lucky Egg", color = C_EGG },
}

local function isPickedUp(item)
    if not item or not slua.isValid(item) then return true end
    if item.bHidden then return true end
    local picked = false
    pcall(function()
        if item.bPickedUp == true then picked = true end
        if item.bIsPickedUp == true then picked = true end
        if item.PickUpState ~= nil and item.PickUpState ~= 0 then picked = true end
        if item.IsPendingKill and item:IsPendingKill() then picked = true end
        if item.Owner and slua.isValid(item.Owner) then picked = true end
    end)
    return picked
end

_G.RunLuckyEggESP = function(pc)
    if not _G.BNTMODConfig.EspLuckyEgg then
        _G.CachedLuckyEggs = {}
        return
    end
    local curTime = _G.RealNow()
    if curTime - (_G.LastScanLuckyEggTime or 0) < 0.3 then return end
    _G.LastScanLuckyEggTime = curTime

    local GameplayData = package.loaded["GameLua.GameCore.Data.GameplayData"]
        or require("GameLua.GameCore.Data.GameplayData")
    local player = GameplayData and GameplayData.GetPlayerCharacter
        and GameplayData.GetPlayerCharacter()
    if not player or not slua.isValid(player) then return end

    local APickUp = import("PickUpWrapperActor") or import("STPickupWrapperActor")
    if not APickUp then return end
    local Actors = Game and Game.GetActorsByClass and Game:GetActorsByClass(APickUp)
    if not Actors then return end

    local candidates = {}
    local count = (Actors.Num and Actors:Num()) or 0
    for i = 0, count - 1 do
        local item = Actors:Get(i)
        if slua.isValid(item) and not item.bHidden then
            local itemId = nil
            if item.DefineID and item.DefineID.TypeSpecificID then
                itemId = item.DefineID.TypeSpecificID
            elseif item.DefineId then
                itemId = item.DefineId
            end
            local data = itemId and LuckyEggDatabase[itemId]
            if data and not isPickedUp(item) then
                local dist = 0
                pcall(function() dist = player:GetDistanceTo(item) end)
                candidates[#candidates + 1] = {
                    act = item,
                    name = data.name,
                    color = data.color,
                    d = dist or 0,
                    off = { X = 0, Y = 0, Z = 40 },
                }
            end
        end
    end
    table.sort(candidates, function(a, b) return (a.d or 0) < (b.d or 0) end)

    local newList = {}
    local maxN = _G.LuckyEggESP_MaxLabels or 40
    for i = 1, math.min(#candidates, maxN) do
        newList[i] = candidates[i]
    end
    _G.CachedLuckyEggs = newList
end

_G.DrawLuckyEggESP = function(pc)
    if not _G.BNTMODConfig.EspLuckyEgg then return end
    local list = _G.CachedLuckyEggs
    if not list or #list == 0 then return end

    local MyHUD = nil
    pcall(function()
        if pc and pc.MyHUD then MyHUD = pc.MyHUD end
        if not MyHUD and slua_GameFrontendHUD then
            local c = slua_GameFrontendHUD:GetPlayerController()
            if c and c.MyHUD then MyHUD = c.MyHUD end
        end
    end)
    if not MyHUD or not MyHUD.AddDebugText then return end

    for _, it in ipairs(list) do
        if not isPickedUp(it.act) then
            local distM = (it.d or 0) / 100
            local grouped = math.floor(distM / 10) * 10
            local scale = math.max(0.7, 1.2 - (grouped / 400))
            local text = string.format("%s [%dm]", it.name, math.floor(distM))
            local col = it.color or C_EGG
            pcall(function()
                MyHUD:AddDebugText(
                    text, it.act,
                    0.06,
                    it.off or { X = 0, Y = 0, Z = 40 },
                    it.off or { X = 0, Y = 0, Z = 40 },
                    col, true, false, true, nil, scale, true
                )
            end)
        end
    end
end

_G.StartLuckyEggESPLoop = function()
    if _G._LuckyEggESPLoopRunning then return end
    _G._LuckyEggESPLoopRunning = true
    local ok, ticker = pcall(require, "common.time_ticker")
    if not (ok and ticker and ticker.AddTimerLoop) then return end

    ticker.AddTimerLoop(0, function()
        pcall(function()
            local GD = package.loaded["GameLua.GameCore.Data.GameplayData"]
                or require("GameLua.GameCore.Data.GameplayData")
            local pc = GD and GD.GetPlayerController and GD.GetPlayerController()
            _G.RunLuckyEggESP(pc)
            _G.DrawLuckyEggESP(pc)
        end)
    end, -1, 0.01)
end

pcall(_G.StartLuckyEggESPLoop)
print("LUCKY EGG ESP LOADED")
    
    pcall(function()
        local weapon = nil
        pcall(function()
            local weaponManager = localPlayer.WeaponManagerComponent
            if Valid(weaponManager) and type(weaponManager.GetCurrentWeapon) == "function" then
                weapon = weaponManager:GetCurrentWeapon()
            end
        end)
        if not Valid(weapon) then
            if type(localPlayer.GetCurrentShootWeapon) == "function" then weapon = localPlayer:GetCurrentShootWeapon()
            elseif type(localPlayer.GetCurrentWeapon) == "function" then weapon = localPlayer:GetCurrentWeapon() end
        end
        if Valid(weapon) then
            local entities = {}
            if Valid(weapon.ShootWeaponEntity_GEN_VARIABLE) then table.insert(entities, weapon.ShootWeaponEntity_GEN_VARIABLE) end
            if Valid(weapon.ShootWeaponEntity) then table.insert(entities, weapon.ShootWeaponEntity) end
            if Valid(weapon.ShootWeaponComponent) and Valid(weapon.ShootWeaponComponent.ShootWeaponEntityComponent) then 
                table.insert(entities, weapon.ShootWeaponComponent.ShootWeaponEntityComponent) 
            end
            for _, entity in ipairs(entities) do
                local crosshairOn = _G.BNTMODConfig.Crosshair or _G.BNTMODConfig.Accuracy
                if crosshairOn then
                    if not entity.OriginalStatsCached then
                        entity.OriginalStatsCached = {
                            GameDeviationFactor = entity.GameDeviationFactor,
                            GameDeviationAccuracy = entity.GameDeviationAccuracy
                        }
                    end
                    if _G.BNTMODConfig.Crosshair then entity.GameDeviationFactor = 0.0 end
                    if _G.BNTMODConfig.Accuracy then entity.GameDeviationAccuracy = 0.0 end
                    entity.CrosshairModActive = true
                elseif entity.CrosshairModActive then
                    if entity.OriginalStatsCached then
                        local orig = entity.OriginalStatsCached
                        entity.GameDeviationFactor = orig.GameDeviationFactor
                        entity.GameDeviationAccuracy = orig.GameDeviationAccuracy
                    end
                    entity.CrosshairModActive = false
                end
            end
        end
    end)

local GameplayData, gameplayDataReady, lockedTarget, lastAimRotation, aimActive = nil, false, nil, nil, false

pcall(function()
	local ok, module = pcall(require, "GameLua.GameCore.Data.GameplayData")
	if ok and module then GameplayData = module; gameplayDataReady = true end
end)

local function valid(v)
	if v == nil then return false end
	local slua = rawget(_G, "slua")
	if slua and type(slua.isValid) == "function" then
		local ok, res = pcall(slua.isValid, v)
		return ok and res == true
	end
	return true
end

local function normalize_angle(a)
	while a > 180.0 do a = a - 360.0 end
	while a < -180.0 do a = a + 360.0 end
	return a
end

local function atan2(y, x)
	if x > 0 then return math.atan(y / x)
	elseif x < 0 and y >= 0 then return math.atan(y / x) + math.pi
	elseif x < 0 and y < 0 then return math.atan(y / x) - math.pi
	elseif x == 0 and y > 0 then return math.pi / 2
	elseif x == 0 and y < 0 then return -math.pi / 2 end
	return 0
end

pcall(function()
	if not _G.BNTMODConfig.MortarAim then
		if aimActive then aimActive = false; lockedTarget = nil; lastAimRotation = nil end
		return
	end
	local uCon = slua_GameFrontendHUD and slua_GameFrontendHUD:GetPlayerController()
	if not valid(uCon) then return end
	local pawn = uCon:GetPlayerCharacterSafety()
	if not valid(pawn) then return end
	local camera = uCon.PlayerCameraManager
	if not valid(camera) then return end

	local camLoc, camRot = camera:GetCameraLocation(), camera:GetCameraRotation()
	if not camLoc or not camRot then return end

	local weapon = pawn.CurrentWeapon or (type(pawn.GetCurrentWeapon) == "function" and pawn:GetCurrentWeapon())
	local mortarState = 0
	pcall(function() mortarState = weapon and weapon.MortarState or 0 end)

	if not valid(weapon) or (mortarState ~= 2 and not string.find(string.lower(tostring(weapon)), "mortar", 1, true)) then
		if aimActive then aimActive = false; lockedTarget = nil; lastAimRotation = nil end
		return
	end
	if not aimActive then aimActive = true end

	local mortarCond = _G.BNTMODState.CustomTextData.MortarCond or 2
	local isFiring = false
	pcall(function() isFiring = weapon.bIsFiring or weapon.IsFiring or false end)
	if mortarCond == 1 and not isFiring then return end

	local maxDistMeters = _G.BNTMODState.CustomTextData.MortarDist or 600
	local fovVal = _G.BNTMODState.CustomTextData.MortarFOV or 40
	local speedVal = _G.BNTMODState.CustomTextData.MortarSpeed or 30

	if lockedTarget and lastAimRotation then
		local y_d = math.abs(normalize_angle(camRot.Yaw - lastAimRotation.Yaw))
		local p_d = math.abs(normalize_angle(camRot.Pitch - lastAimRotation.Pitch))
		if y_d > 3.5 or p_d > 3.5 then lockedTarget = nil; lastAimRotation = nil end
	end
	if lockedTarget then
		local pLoc, tLoc = pawn:K2_GetActorLocation(), lockedTarget:K2_GetActorLocation()
		if not pLoc or not tLoc or (lockedTarget.bDead == true) or (math.sqrt((tLoc.X - pLoc.X)^2 + (tLoc.Y - pLoc.Y)^2) / 100.0 > maxDistMeters) then
			lockedTarget = nil
		end
	end
	if not lockedTarget and GameplayData then
		local bestScore, bestTarget = fovVal, nil
		local function scan(list)
			if type(list) ~= "table" then return end
			for _, actor in pairs(list) do
				if valid(actor) and actor ~= pawn then
					local tLoc = actor:K2_GetActorLocation()
					if tLoc then
						local dx, dy = tLoc.X - camLoc.X, tLoc.Y - camLoc.Y
						local horiz = math.sqrt(dx * dx + dy * dy)
						if (horiz / 100.0) <= maxDistMeters then
							local yaw = atan2(dy, dx) * (180.0 / math.pi)
							local y_d = math.abs(normalize_angle(yaw - camRot.Yaw))
							if y_d <= fovVal then
								if y_d < bestScore then bestScore = y_d; bestTarget = actor end
							end
						end
					end
				end
			end
		end
		if type(GameplayData.GetAllPlayerCharacters) == "function" then scan(GameplayData.GetAllPlayerCharacters()) end
		lockedTarget = bestTarget
	end
	if lockedTarget then
		local pLoc, tLoc = pawn:K2_GetActorLocation(), lockedTarget:K2_GetActorLocation()
		if pLoc and tLoc then
			local dx, dy, dz = tLoc.X - pLoc.X, tLoc.Y - pLoc.Y, tLoc.Z - pLoc.Z
			local horiz = math.sqrt(dx * dx + dy * dy)
			local vel = 9070.0
			pcall(function() vel = tonumber(weapon:GetBulletFireSpeedFromEntity()) or 9070.0 end)
			local g = 980.0 * 2.8
			local v2, v4 = vel * vel, (vel * vel) * (vel * vel)
			local disc = v4 - (g * g * horiz * horiz) - (2.0 * g * dz * v2)
			local b_pitch = disc < 0 and 45.0 or math.min(88.0, math.max(45.0, math.atan((v2 + math.sqrt(disc)) / (g * horiz)) * (180.0 / math.pi)))
			local pitch = math.min(30.0, math.max(-60.0, (b_pitch - 45.0) * 2.093 - 60.0))
			local yaw = atan2(dy, dx) * (180.0 / math.pi)
			local targetRot = FRotator(pitch, yaw, 0)
			local interpSpeed = math.max(1, speedVal) * 0.1
			local currentRot = camRot
			local finalPitch = currentRot.Pitch + (normalize_angle(targetRot.Pitch - currentRot.Pitch) * interpSpeed)
			local finalYaw = currentRot.Yaw + (normalize_angle(targetRot.Yaw - currentRot.Yaw) * interpSpeed)
			local rot = FRotator(finalPitch, finalYaw, 0)
			pcall(function()
				camera.bLimitViewPitch, camera.bLimitViewYaw = false, false
				camera.ViewPitchMin, camera.ViewPitchMax = -89.9, 89.9
				if type(pawn.K2_SetActorRotation) == "function" then pawn:K2_SetActorRotation(FRotator(0, finalYaw, 0), false) end
				pawn.BaseAimRotation, uCon.ControlRotation = rot, rot
			end)
			lastAimRotation = rot
		end
	end
end) 

if _G.BNTMODConfig and (_G.BNTMODConfig.EspRifleCategory or _G.BNTMODConfig.EspSniperCategory or _G.BNTMODConfig.EspSMGCategory or _G.BNTMODConfig.EspShotgunCategory or _G.BNTMODConfig.EspVehicleCategory) then
    pcall(function()
        local MyHUD = Cached_MyHUD
        if Valid(MyHUD) then
            if not _G.CachedGameplayStatics then _G.CachedGameplayStatics = import("GameplayStatics") end
            if not _G.CachedActorClass_ForWeapon then _G.CachedActorClass_ForWeapon = import("Actor") end 
            if not _G.CachedWeaponArray then _G.CachedWeaponArray = slua.Array(UEnums.EPropertyClass.Object, _G.CachedActorClass_ForWeapon) end
            if not _G.ActorWeaponCacheInit then
                _G.NonWeaponCache = setmetatable({}, { __mode = "k" })
                _G.ActorWeaponCacheInit = true
            end
            if not _G.ActorVehicleCacheInit then
                _G.NonVehicleCache = setmetatable({}, { __mode = "k" })
                _G.ActorVehicleCacheInit = true
            end
            local ui_util = require("client.common.ui_util")
            local gameInstance = ui_util and ui_util.GetGameInstance()
            if gameInstance and _G.CachedGameplayStatics then
                local curTime = os.clock()
                if not _G.LastWeaponScanTime or (curTime - _G.LastWeaponScanTime) > SCAN_INTERVAL then
                    _G.LastWeaponScanTime = curTime
                    local allActors = _G.CachedGameplayStatics.GetAllActorsOfClass(gameInstance, _G.CachedActorClass_ForWeapon, _G.CachedWeaponArray)
                    local weaponList = {}
                    local vehicleList = {}
                    if allActors then
                        for _, actor in pairs(allActors) do
                            if slua.isValid(actor) and not actor.bHidden and not actor.bTearOff then
                                if not _G.NonWeaponCache[actor] then
                                    local isMatchedWeapon = false
                                    local detectedWeaponName = "WEAPON"
                                    local nameLower = nil
                                    pcall(function() nameLower = string.lower(type(actor.GetName) == "function" and actor:GetName() or tostring(actor)) end)
                                    if nameLower then
                                        if string.find(nameLower, "m416") or string.find(nameLower, "rifle_m4") then isMatchedWeapon, detectedWeaponName = true, "M416"
                                        elseif string.find(nameLower, "akm") then isMatchedWeapon, detectedWeaponName = true, "AKM"
                                        elseif string.find(nameLower, "scar") then isMatchedWeapon, detectedWeaponName = true, "SCAR-L"
                                        elseif string.find(nameLower, "m16a4") then isMatchedWeapon, detectedWeaponName = true, "M16A4"
                                        elseif string.find(nameLower, "m762") then isMatchedWeapon, detectedWeaponName = true, "M762"
                                        elseif string.find(nameLower, "groza") then isMatchedWeapon, detectedWeaponName = true, "Groza"
                                        elseif string.find(nameLower, "aug") then isMatchedWeapon, detectedWeaponName = true, "AUG"
                                        elseif string.find(nameLower, "qbz") then isMatchedWeapon, detectedWeaponName = true, "QBZ"
                                        elseif string.find(nameLower, "g36c") then isMatchedWeapon, detectedWeaponName = true, "G36C"
                                        elseif string.find(nameLower, "famas") then isMatchedWeapon, detectedWeaponName = true, "FAMAS"
                                        elseif string.find(nameLower, "kar98k") then isMatchedWeapon, detectedWeaponName = true, "Kar98k"
                                        elseif string.find(nameLower, "m24") then isMatchedWeapon, detectedWeaponName = true, "M24"
                                        elseif string.find(nameLower, "awm") then isMatchedWeapon, detectedWeaponName = true, "AWM"
                                        elseif string.find(nameLower, "sks") then isMatchedWeapon, detectedWeaponName = true, "SKS"
                                        elseif string.find(nameLower, "slr") then isMatchedWeapon, detectedWeaponName = true, "SLR"
                                        elseif string.find(nameLower, "mini14") then isMatchedWeapon, detectedWeaponName = true, "Mini14"
                                        elseif string.find(nameLower, "mk14") then isMatchedWeapon, detectedWeaponName = true, "Mk14"
                                        elseif string.find(nameLower, "vss") then isMatchedWeapon, detectedWeaponName = true, "VSS"
                                        elseif string.find(nameLower, "qbu") then isMatchedWeapon, detectedWeaponName = true, "QBU"
                                        elseif string.find(nameLower, "mosin") then isMatchedWeapon, detectedWeaponName = true, "Mosin"
                                        elseif string.find(nameLower, "amr") or string.find(nameLower, "lynx") then isMatchedWeapon, detectedWeaponName = true, "AMR"
                                        elseif string.find(nameLower, "ump45") or string.find(nameLower, "ump9") then isMatchedWeapon, detectedWeaponName = true, "UMP45"
                                        elseif string.find(nameLower, "uzi") then isMatchedWeapon, detectedWeaponName = true, "UZI"
                                        elseif string.find(nameLower, "vector") then isMatchedWeapon, detectedWeaponName = true, "Vector"
                                        elseif string.find(nameLower, "thompson") or string.find(nameLower, "tommy") then isMatchedWeapon, detectedWeaponName = true, "Tommy"
                                        elseif string.find(nameLower, "bizon") then isMatchedWeapon, detectedWeaponName = true, "Bizon"
                                        elseif string.find(nameLower, "mp5k") then isMatchedWeapon, detectedWeaponName = true, "MP5K"
                                        elseif string.find(nameLower, "p90") then isMatchedWeapon, detectedWeaponName = true, "P90"
                                        elseif string.find(nameLower, "m249") then isMatchedWeapon, detectedWeaponName = true, "M249"
                                        elseif string.find(nameLower, "dp28") then isMatchedWeapon, detectedWeaponName = true, "DP-28"
                                        elseif string.find(nameLower, "mg3") then isMatchedWeapon, detectedWeaponName = true, "MG3"
                                        elseif string.find(nameLower, "s686") then isMatchedWeapon, detectedWeaponName = true, "S686"
                                        elseif string.find(nameLower, "s1897") then isMatchedWeapon, detectedWeaponName = true, "S1897"
                                        elseif string.find(nameLower, "s12k") then isMatchedWeapon, detectedWeaponName = true, "S12K"
                                        elseif string.find(nameLower, "dbs") then isMatchedWeapon, detectedWeaponName = true, "DBS"
                                        elseif string.find(nameLower, "o12") or string.find(nameLower, "origin") then isMatchedWeapon, detectedWeaponName = true, "Origin 12"
                                        elseif string.find(nameLower, "crossbow") then isMatchedWeapon, detectedWeaponName = true, "Crossbow"
                                        elseif string.find(nameLower, "deagle") then isMatchedWeapon, detectedWeaponName = true, "Deagle"
                                        elseif string.find(nameLower, "flare") then isMatchedWeapon, detectedWeaponName = true, "Flare"
                                        end
                                    end
                                    local shouldShowWeapon = false
                                    if isMatchedWeapon then
                                        if detectedWeaponName == "M416" and _G.BNTMODConfig.Weapon_M416 then shouldShowWeapon = true end
                                        if detectedWeaponName == "AKM" and _G.BNTMODConfig.Weapon_AKM then shouldShowWeapon = true end
                                        if detectedWeaponName == "SCAR-L" and _G.BNTMODConfig.Weapon_SCAR then shouldShowWeapon = true end
                                        if detectedWeaponName == "M16A4" and _G.BNTMODConfig.Weapon_M16A4 then shouldShowWeapon = true end
                                        if detectedWeaponName == "M762" and _G.BNTMODConfig.Weapon_M762 then shouldShowWeapon = true end
                                        if detectedWeaponName == "Groza" and _G.BNTMODConfig.Weapon_Groza then shouldShowWeapon = true end
                                        if detectedWeaponName == "AUG" and _G.BNTMODConfig.Weapon_AUG then shouldShowWeapon = true end
                                        if detectedWeaponName == "QBZ" and _G.BNTMODConfig.Weapon_QBZ then shouldShowWeapon = true end
                                        if detectedWeaponName == "G36C" and _G.BNTMODConfig.Weapon_G36C then shouldShowWeapon = true end
                                        if detectedWeaponName == "FAMAS" and _G.BNTMODConfig.Weapon_FAMAS then shouldShowWeapon = true end
                                        if detectedWeaponName == "Kar98k" and _G.BNTMODConfig.Weapon_Kar98k then shouldShowWeapon = true end
                                        if detectedWeaponName == "M24" and _G.BNTMODConfig.Weapon_M24 then shouldShowWeapon = true end
                                        if detectedWeaponName == "AWM" and _G.BNTMODConfig.Weapon_AWM then shouldShowWeapon = true end
                                        if detectedWeaponName == "SKS" and _G.BNTMODConfig.Weapon_SKS then shouldShowWeapon = true end
                                        if detectedWeaponName == "SLR" and _G.BNTMODConfig.Weapon_SLR then shouldShowWeapon = true end
                                        if detectedWeaponName == "Mini14" and _G.BNTMODConfig.Weapon_Mini14 then shouldShowWeapon = true end
                                        if detectedWeaponName == "Mk14" and _G.BNTMODConfig.Weapon_Mk14 then shouldShowWeapon = true end
                                        if detectedWeaponName == "VSS" and _G.BNTMODConfig.Weapon_VSS then shouldShowWeapon = true end
                                        if detectedWeaponName == "QBU" and _G.BNTMODConfig.Weapon_QBU then shouldShowWeapon = true end
                                        if detectedWeaponName == "Mosin" and _G.BNTMODConfig.Weapon_Mosin then shouldShowWeapon = true end
                                        if detectedWeaponName == "AMR" and _G.BNTMODConfig.Weapon_AMR then shouldShowWeapon = true end
                                        if detectedWeaponName == "UMP45" and _G.BNTMODConfig.Weapon_UMP45 then shouldShowWeapon = true end
                                        if detectedWeaponName == "UZI" and _G.BNTMODConfig.Weapon_UZI then shouldShowWeapon = true end
                                        if detectedWeaponName == "Vector" and _G.BNTMODConfig.Weapon_Vector then shouldShowWeapon = true end
                                        if detectedWeaponName == "Tommy" and _G.BNTMODConfig.Weapon_Tommy then shouldShowWeapon = true end
                                        if detectedWeaponName == "Bizon" and _G.BNTMODConfig.Weapon_Bizon then shouldShowWeapon = true end
                                        if detectedWeaponName == "MP5K" and _G.BNTMODConfig.Weapon_MP5K then shouldShowWeapon = true end
                                        if detectedWeaponName == "P90" and _G.BNTMODConfig.Weapon_P90 then shouldShowWeapon = true end
                                        if detectedWeaponName == "M249" and _G.BNTMODConfig.Weapon_M249 then shouldShowWeapon = true end
                                        if detectedWeaponName == "DP-28" and _G.BNTMODConfig.Weapon_DP28 then shouldShowWeapon = true end
                                        if detectedWeaponName == "MG3" and _G.BNTMODConfig.Weapon_MG3 then shouldShowWeapon = true end
                                        if detectedWeaponName == "S686" and _G.BNTMODConfig.Weapon_S686 then shouldShowWeapon = true end
                                        if detectedWeaponName == "S1897" and _G.BNTMODConfig.Weapon_S1897 then shouldShowWeapon = true end
                                        if detectedWeaponName == "S12K" and _G.BNTMODConfig.Weapon_S12K then shouldShowWeapon = true end
                                        if detectedWeaponName == "DBS" and _G.BNTMODConfig.Weapon_DBS then shouldShowWeapon = true end
                                        if detectedWeaponName == "Origin 12" and _G.BNTMODConfig.Weapon_Origin then shouldShowWeapon = true end
                                        if detectedWeaponName == "Crossbow" and _G.BNTMODConfig.Weapon_Crossbow then shouldShowWeapon = true end
                                        if detectedWeaponName == "Deagle" and _G.BNTMODConfig.Weapon_Deagle then shouldShowWeapon = true end
                                        if detectedWeaponName == "Flare" and _G.BNTMODConfig.Weapon_Flare then shouldShowWeapon = true end
                                    end
                                    if shouldShowWeapon then table.insert(weaponList, {actor = actor, name = detectedWeaponName})
                                    else _G.NonWeaponCache[actor] = true end
                                end
                                if _G.BNTMODConfig.EspVehicleCategory and not _G.NonVehicleCache[actor] then
                                    local isMatchedVeh = false
                                    local detectedVehName = "VEHICLE"
                                    local nameLowerVeh = nil
                                    pcall(function() nameLowerVeh = string.lower(type(actor.GetName) == "function" and actor:GetName() or tostring(actor)) end)
                                    if nameLowerVeh then
                                        if string.find(nameLowerVeh, "mirado") then isMatchedVeh, detectedVehName = true, "Mirado"
                                        elseif string.find(nameLowerVeh, "dacia") then isMatchedVeh, detectedVehName = true, "Dacia"
                                        elseif string.find(nameLowerVeh, "buggy") then isMatchedVeh, detectedVehName = true, "Buggy"
                                        elseif string.find(nameLowerVeh, "uaz") then isMatchedVeh, detectedVehName = true, "UAZ"
                                        elseif string.find(nameLowerVeh, "sedan") or string.find(nameLowerVeh, "coupe") then isMatchedVeh, detectedVehName = true, "Coupe"
                                        elseif string.find(nameLowerVeh, "motorcycle") or string.find(nameLowerVeh, "bike") then isMatchedVeh, detectedVehName = true, "Motorcycle"
                                        elseif string.find(nameLowerVeh, "helicopter") then isMatchedVeh, detectedVehName = true, "Heli"
                                        elseif string.find(nameLowerVeh, "brdm") then isMatchedVeh, detectedVehName = true, "BRDM"
                                        elseif string.find(nameLowerVeh, "minibus") then isMatchedVeh, detectedVehName = true, "Minibus"
                                        elseif string.find(nameLowerVeh, "monstertruck") then isMatchedVeh, detectedVehName = true, "MonsterTruck"
                                        elseif string.find(nameLowerVeh, "pickup") or string.find(nameLowerVeh, "rony") then isMatchedVeh, detectedVehName = true, "Pickup"
                                        end
                                    end
                                    local shouldShowVeh = false
                                    if isMatchedVeh then
                                        if detectedVehName == "Mirado" and _G.BNTMODConfig.Veh_MiradoOrange then shouldShowVeh = true end
                                        if detectedVehName == "Dacia" and _G.BNTMODConfig.Veh_Dacia then shouldShowVeh = true end
                                        if detectedVehName == "Buggy" and _G.BNTMODConfig.Veh_Buggy then shouldShowVeh = true end
                                        if detectedVehName == "Coupe" and _G.BNTMODConfig.Veh_UAZ_Old then shouldShowVeh = true end
                                        if detectedVehName == "Motorcycle" and _G.BNTMODConfig.Veh_Motorcycle then shouldShowVeh = true end
                                        if detectedVehName == "Heli" and _G.BNTMODConfig.Veh_Helicopter then shouldShowVeh = true end
                                        if detectedVehName == "BRDM" and _G.BNTMODConfig.Veh_BRDM then shouldShowVeh = true end
                                        if detectedVehName == "Minibus" and _G.BNTMODConfig.Veh_Minibus then shouldShowVeh = true end
                                        if detectedVehName == "MonsterTruck" and _G.BNTMODConfig.Veh_MonsterTruck then shouldShowVeh = true end
                                        if detectedVehName == "UAZ" and _G.BNTMODConfig.Veh_UAZ then shouldShowVeh = true end
                                        if detectedVehName == "Pickup" and _G.BNTMODConfig.Veh_Pickup then shouldShowVeh = true end
                                    end
                                    if shouldShowVeh then table.insert(vehicleList, {actor = actor, name = detectedVehName})
                                    else _G.NonVehicleCache[actor] = true end
                                end
                            end
                        end
                    end
                    _G.CachedWeaponList = weaponList
                    _G.CachedVehicleList = vehicleList
                end
                if _G.CachedWeaponList then
                    for _, item in ipairs(_G.CachedWeaponList) do
                        local weapon = item.actor
                        if slua.isValid(weapon) and not weapon.bHidden then
                            local distM = 0
                            pcall(function() distM = localPlayer:GetDistanceTo(weapon) / 100 end)
                            if distM > 1.5 and distM <= 100 then
                                local text = string.format("%s [%dm]", item.name, math.floor(distM))
                                local weaponColor = {R = 0, G = 255, B = 255, A = 255}
                                local dynamicScale = math.max(0.6, 1.1 - (distM / 200))
                                MyHUD:AddDebugText(text, weapon, 1.0, {X=0, Y=0, Z=100}, {X=0, Y=0, Z=100}, weaponColor, true, false, true, nil, dynamicScale, true)
                            end
                        end
                    end
                end
                if _G.CachedVehicleList then
                    for _, item in ipairs(_G.CachedVehicleList) do
                        local vehicle = item.actor
                        if slua.isValid(vehicle) and not vehicle.bHidden then
                            local distM = 0
                            pcall(function() distM = localPlayer:GetDistanceTo(vehicle) / 100 end)
                            if distM > 3 and distM <= 150 then
                                local text = string.format("[%s] %dm", item.name, math.floor(distM))
                                local vehicleColor = {R = 255, G = 165, B = 0, A = 255}
                                local dynamicScale = math.max(0.6, 1.1 - (distM / 500))
                                MyHUD:AddDebugText(text, vehicle, 1.0, {X=0, Y=0, Z=100}, {X=0, Y=0, Z=100}, vehicleColor, true, false, true, nil, dynamicScale, true)
                            end
                        end
                    end
                end
            end
        end
    end)
end
       
    pcall(function()
        local weapon = nil
        pcall(function()
            local weaponManager = localPlayer.WeaponManagerComponent
            if Valid(weaponManager) and type(weaponManager.GetCurrentWeapon) == "function" then
                weapon = weaponManager:GetCurrentWeapon()
            end
        end)
        if not Valid(weapon) then
            if type(localPlayer.GetCurrentShootWeapon) == "function" then weapon = localPlayer:GetCurrentShootWeapon()
            elseif type(localPlayer.GetCurrentWeapon) == "function" then weapon = localPlayer:GetCurrentWeapon() end
        end
        if Valid(weapon) then
            local entities = {}
            if Valid(weapon.ShootWeaponEntity_GEN_VARIABLE) then table.insert(entities, weapon.ShootWeaponEntity_GEN_VARIABLE) end
            if Valid(weapon.ShootWeaponEntity) then table.insert(entities, weapon.ShootWeaponEntity) end
            if Valid(weapon.ShootWeaponComponent) and Valid(weapon.ShootWeaponComponent.ShootWeaponEntityComponent) then 
                table.insert(entities, weapon.ShootWeaponComponent.ShootWeaponEntityComponent) 
            end
            for _, entity in ipairs(entities) do
                local anyWeaponModOn = _G.BNTMODConfig.CustomHRecoil or _G.BNTMODConfig.CustomVRecoil or _G.BNTMODConfig.LessShake or _G.BNTMODConfig.Accuracy or _G.BNTMODConfig.Crosshair or _G.BNTMODConfig.CustomAimbot or _G.BNTMODConfig.CustomAimbotClose
                if anyWeaponModOn then
                    if not entity.OriginalStatsCached then
                        entity.OriginalStatsCached = {
                            GameDeviationFactor = entity.GameDeviationFactor,
                            GameDeviationAccuracy = entity.GameDeviationAccuracy,
                            BulletFireSpeed = entity.BulletFireSpeed,
                            ShootInterval = entity.ShootInterval,
                            BaseDamage = entity.BaseDamage,
                            AccessoriesHRecoilFactor = entity.AccessoriesHRecoilFactor,
                            AccessoriesVRecoilFactor = entity.AccessoriesVRecoilFactor,
                            RecoilKick = entity.RecoilKick,
                            RecoilKickADS = entity.RecoilKickADS,
                            AnimationKick = entity.AnimationKick
                        }
                    end
                    if _G.BNTMODConfig.CustomHRecoil then entity.AccessoriesHRecoilFactor = _G.BNTMODState.CustomTextData.HRecoil or 0.3 
                    elseif _G.BNTMODConfig.LessRecoil then entity.AccessoriesHRecoilFactor = 0.3 end
                    if _G.BNTMODConfig.CustomVRecoil then entity.AccessoriesVRecoilFactor = _G.BNTMODState.CustomTextData.VRecoil or 0.3
                    elseif _G.BNTMODConfig.VerticalRecoil then entity.AccessoriesVRecoilFactor = 0.3 end
                    if _G.BNTMODConfig.LessShake then entity.RecoilKickADS = 0.0 end
                    if _G.BNTMODConfig.Accuracy then entity.GameDeviationAccuracy = 0.0 end
                    if _G.BNTMODConfig.Crosshair then entity.GameDeviationFactor = 0.0 end
                    entity.BNTMODWeaponModsActive = true
                elseif entity.BNTMODWeaponModsActive then
                    if entity.OriginalStatsCached then
                        local orig = entity.OriginalStatsCached
                        entity.GameDeviationFactor = orig.GameDeviationFactor
                        entity.GameDeviationAccuracy = orig.GameDeviationAccuracy
                        entity.BulletFireSpeed = orig.BulletFireSpeed
                        entity.ShootInterval = orig.ShootInterval
                        entity.BaseDamage = orig.BaseDamage
                        entity.AccessoriesHRecoilFactor = orig.AccessoriesHRecoilFactor
                        entity.AccessoriesVRecoilFactor = orig.AccessoriesVRecoilFactor
                        entity.RecoilKick = orig.RecoilKick
                        entity.RecoilKickADS = orig.RecoilKickADS
                        entity.AnimationKick = orig.AnimationKick
                    end
                    entity.BNTMODWeaponModsActive = false
                end
            end
        end
    end)

    pcall(function()
        local allCharacters = {}
        if GameplayData.GetAllPlayerCharacters then allCharacters = GameplayData.GetAllPlayerCharacters()
        elseif GameplayData.GameCharacters then for _, char in pairs(GameplayData.GameCharacters) do table.insert(allCharacters, char) end end
        
        local currentValidKeys = {}
        for _, enemy in pairs(allCharacters) do
            if Valid(enemy) and enemy ~= localPlayer then currentValidKeys[GetSafeEnemyKey(enemy)] = true end
        end
        for key, data in pairs(_G.BNTMODState.EnemyMarks) do
            if not currentValidKeys[key] then
                SafeRemoveMark(data.radarMark); SafeRemoveMark(data.hpMark); SafeRemoveMark(data.distMark)
                if _G.AimTouchVisCache and _G.AimTouchVisCache[key] then _G.AimTouchVisCache[key] = nil end
                data.enemy = nil
                data.CachedMeshes = nil
                _G.BNTMODState.EnemyMarks[key] = nil
            end
        end

        local realCount = 0
        local aiCount = 0
        local mLoc = nil
        pcall(function() if type(localPlayer.K2_GetActorLocation) == "function" then mLoc = localPlayer:K2_GetActorLocation() end end)

        for _, enemy in pairs(allCharacters) do
            if Valid(enemy) and enemy ~= localPlayer and enemy.TeamID ~= localPlayer.TeamID then
                local bIsReallyDead = false
                pcall(function()
                    if type(enemy.IsDead) == "function" then bIsReallyDead = enemy:IsDead()
                    elseif enemy.bIsDead ~= nil then bIsReallyDead = enemy.bIsDead
                    elseif enemy.bIsDeadFlag ~= nil then bIsReallyDead = enemy.bIsDeadFlag end
                    if enemy.HealthStatus ~= nil and enemy.HealthStatus == 2 then bIsReallyDead = true end
                end)

                local eKey = GetSafeEnemyKey(enemy)
                _G.BNTMODState.EnemyMarks[eKey] = _G.BNTMODState.EnemyMarks[eKey] or { enemy = enemy }
                local markData = _G.BNTMODState.EnemyMarks[eKey]
                markData.enemy = enemy 

                if not bIsReallyDead then
                    if markData.lastEnemyActor ~= enemy then
                        if markData.hpMark then SafeRemoveMark(markData.hpMark); markData.hpMark = nil end
                        if markData.distMark then SafeRemoveMark(markData.distMark); markData.distMark = nil end
                        if markData.radarMark then SafeRemoveMark(markData.radarMark); markData.radarMark = nil end
                        markData.lastEnemyActor = enemy
                        markData.LastFrameUIState = nil
                    end
                    
                    local eMesh = nil
                    pcall(function() eMesh = enemy.Mesh or (type(enemy.getAvatarComponent2) == "function" and enemy:getAvatarComponent2() or nil) end)
                    local aLoc = nil
                    pcall(function() if type(enemy.K2_GetActorLocation) == "function" then aLoc = enemy:K2_GetActorLocation() end end)
                    
                    CheckIsAI(enemy, markData)

                    -- ColorBodyNew
                    if _G.BNTMODConfig.ColorBodyNew then 
                        ApplyColorBodyNew(enemy, markData)
                    else
                        UndoColorBodyNew(enemy, markData)
                    end

                    local distM = 0
                    pcall(function() distM = localPlayer:GetDistanceTo(enemy) / 100 end)

                    if distM <= ESP_MAX_DIST then
                        local currentHp, maxHp = 100, 100
                        local showFrameUI = _G.BNTMODConfig.EspVip or _G.BNTMODConfig.EspVipPro
                    if showFrameUI then
                        pcall(function()
                            if enemy.Health then currentHp = enemy.Health elseif type(enemy.GetHealth) == "function" then currentHp = enemy:GetHealth() end
                            if enemy.HealthMax then maxHp = enemy.HealthMax elseif type(enemy.GetHealthMax) == "function" then maxHp = enemy:GetHealthMax() end
                        end)
                        if maxHp <= 0 then maxHp = 100 end
                    end
                    local hpRatio = currentHp / maxHp

                    if _G.BNTMODConfig.EspAntenna then
                        pcall(function()
                            local MyHUD = Cached_MyHUD
                            if Valid(MyHUD) and distM <= 400 then
                                local loopCount = 8  
                                local zStep = 1000     
                                local baseZ = 105     
                                local topZ = baseZ + (loopCount * zStep)
                                for i = 1, loopCount do
                                    local zOffset = baseZ + (i * zStep)
                                    MyHUD:AddDebugText("|", enemy, 0.06,
                                        {X=0, Y=0, Z=zOffset}, {X=0, Y=0, Z=zOffset},
                                        C_GREEN, true, false, true, nil, 1.2, true)
                                end
                                MyHUD:AddDebugText("I", enemy, 0.06,
                                        {X=0, Y=0, Z=topZ + 60}, {X=0, Y=0, Z=topZ + 60},
                                        C_GREEN, true, false, true, nil, 1.5, true)
                            end
                        end)
                    end

                        if _G.BNTMODConfig.Esp6 then
                            pcall(function()
                                local curTime = os.clock()
                                if markData.LastEsp6Time == nil or (curTime - markData.LastEsp6Time) >= ESP6_UPDATE_INTERVAL then
                                    markData.LastEsp6Time = curTime
                                    local MyHUD = Cached_MyHUD
                                    if Valid(MyHUD) and Valid(eMesh) and aLoc then
                                        if distM <= 150 then
                                            if type(eMesh.GetSocketLocation) == "function" then
                                                local boneList = (distM > BONE_LOD_DIST) and GLOBAL_BONE_LIST_LOW or GLOBAL_BONE_LIST
                                                for _, bName in ipairs(boneList) do
                                                    local wLoc = eMesh:GetSocketLocation(bName)
                                                    if wLoc then
                                                        local offset = {X = wLoc.X - aLoc.X, Y = wLoc.Y - aLoc.Y, Z = wLoc.Z - aLoc.Z}
                                                        local mark = "▪"
                                                        local fixedSize = 0.25 
                                                        local color = C_CYAN
                                                        if bName == "head" then mark = "●"; fixedSize = 0.45; color = C_RED
                                                        elseif bName == "pelvis" or bName == "neck_01" then mark = "▪"; fixedSize = 0.35; color = C_YELLOW end
                                                        MyHUD:AddDebugText(mark, enemy, 0.06, offset, offset, color, true, false, true, nil, fixedSize, true)
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end)
                        end

                        if _G.BNTMODConfig.Esp7 then
                            local myTeamId = localPlayer.TeamID or localPlayer:GetTeamID() or 0
                            local targetTeamId = enemy.TeamID or enemy:GetTeamID() or 0
                            if targetTeamId ~= myTeamId then
                                local isAI = markData.AK_IS_BOT or false
                                if isAI then aiCount = aiCount + 1 else realCount = realCount + 1 end
                            end
                        end

                    if showFrameUI then
                        pcall(function()
                            local SecurityCommonUtils = Cached_SecurityCommonUtils
                            local show = true
                            if enemy.HealthStatus and SecurityCommonUtils and SecurityCommonUtils.IsHealthStatusAlive then 
                                if not SecurityCommonUtils.IsHealthStatusAlive(enemy.HealthStatus) then show = false end
                            end
                            if show and mLoc then
                                if aLoc and SecurityCommonUtils and SecurityCommonUtils.IsVector then
                                    if SecurityCommonUtils.IsVector(aLoc) and SecurityCommonUtils.IsVector(mLoc) then
                                        if aLoc.Z >= 150000 or FVector.Dist2D(mLoc, aLoc) > 50000 then show = false end
                                    end
                                end
                            end
                            if show then
                                if enemy.Replay_IsEnemyFrameUIExisted and not enemy:Replay_IsEnemyFrameUIExisted() then enemy:Replay_CreateEnemyFrameUI(true, true) end
                                if enemy.Replay_SetVisiableOfFrameUI then enemy:Replay_SetVisiableOfFrameUI(true) end
                                if enemy.Replay_UpdateEnemyFrameUI then enemy:Replay_UpdateEnemyFrameUI(hpRatio) end
                                
                                local uiComp = enemy.EnemyFrameUI or (type(enemy.GetEnemyFrameUI) == "function" and enemy:GetEnemyFrameUI())
                                if Valid(uiComp) then
                                    if markData.LastFrameUIState ~= "VISIBLE" then
                                        if type(uiComp.SetVisibility) == "function" then uiComp:SetVisibility(0) end
                                        if type(uiComp.SetHiddenInGame) == "function" then uiComp:SetHiddenInGame(false) end
                                        markData.LastFrameUIState = "VISIBLE"
                                    end
                                end
                            end
                        end)
                    else
                        pcall(function()
                            if enemy.Replay_SetVisiableOfFrameUI then enemy:Replay_SetVisiableOfFrameUI(false) end
                            local uiComp = enemy.EnemyFrameUI or (type(enemy.GetEnemyFrameUI) == "function" and enemy:GetEnemyFrameUI())
                            if Valid(uiComp) then
                                if markData.LastFrameUIState ~= "HIDDEN" then
                                    if type(uiComp.SetVisibility) == "function" then uiComp:SetVisibility(2) end
                                    if type(uiComp.SetHiddenInGame) == "function" then uiComp:SetHiddenInGame(true) end
                                    markData.LastFrameUIState = "HIDDEN"
                                end
                            end
                        end)
                    end

                        if _G.BNTMODConfig.EspVipPro then
                            pcall(function()
                                local hud = Cached_MyHUD
                                if not (Valid(hud) and hud.AddDebugText) then return end
                                local hp = enemy.Health or 100
                                local maxHp = enemy.HealthMax or 100
                                local isKnock = (hp <= 0 or enemy.HealthStatus == 1)
                                local hpPercent = isKnock and 0 or (hp / maxHp)
                                local pctValue = math.floor(hpPercent * 100 + 0.5)
                                local pName = ""
                                if _G.BNTMODConfig.EspName then pName = enemy.PlayerName or enemy.PlayerNamePublic or "Enemy" end
                                local bIsVisible = false
                                if pc and type(pc.LineOfSightTo) == "function" then bIsVisible = pc:LineOfSightTo(enemy) end
                                local textColor = {R=255, G=255, B=255, A=255}
                                if isKnock then textColor = {R=0, G=0, B=255, A=255}
                                else textColor = bIsVisible and {R=0, G=255, B=0, A=255} or {R=255, G=0, B=0, A=255} end
                                local label = ""
                                if isKnock then label = (pName ~= "" and string.format("%s [♿]", pName) or "♿")
                                else
                                    if pName ~= "" then label = string.format("%s ▶ %.0f%%", pName, pctValue)
                                    else label = string.format("▶ %.0f%%", pctValue) end
                                end
                                hud:AddDebugText(label, enemy, 0.2, {X=0, Y=0, Z=120}, {X=0, Y=0, Z=120}, textColor, true, false, true, nil, 1.0, true)
                            end)
                        end

                        if _G.BNTMODConfig.EspName and not _G.BNTMODConfig.EspVipPro then
                            pcall(function()
                                local hud = Cached_MyHUD
                                if not (Valid(hud) and hud.AddDebugText) then return end
                                local pName = enemy.PlayerName or enemy.PlayerNamePublic or "Enemy"
                                if pName == "" then return end
                                local isKnock = (enemy.Health or 100) <= 0 or enemy.HealthStatus == 1
                                local bIsVisible = true
                                pcall(function()
                                    if pc and type(pc.LineOfSightTo) == "function" then bIsVisible = pc:LineOfSightTo(enemy) end
                                end)
                                local nameColor = {R=255, G=255, B=255, A=255}
                                if isKnock then nameColor = {R=0, G=0, B=255, A=255}
                                else nameColor = bIsVisible and {R=0, G=255, B=0, A=255} or {R=255, G=0, B=0, A=255} end
                                hud:AddDebugText(pName, enemy, 0.2, {X=0, Y=0, Z=120}, {X=0, Y=0, Z=120}, nameColor, true, false, true, nil, 1.0, true)
                            end)
                        end

                        if _G.BNTMODConfig.EspVip then
                            if markData.hpMark == nil then markData.hpMark = SafeAddMark(1006, FVector(0,0,0), 0, "", 4, enemy) end
                            if markData.distMark == nil then markData.distMark = SafeAddMark(9999, FVector(0,0,0), 0, "", 4, enemy) end
                        else
                            if markData.hpMark then SafeRemoveMark(markData.hpMark); markData.hpMark = nil end
                            if markData.distMark then SafeRemoveMark(markData.distMark); markData.distMark = nil end
                        end
                        if _G.BNTMODConfig.EspRadar then
                            if not markData.radarMark or markData.radarMark == 0 then 
                                markData.radarMark = SafeAddMark(8888, FVector(0,0,0), 0, "", 4, enemy) 
                            end
                        else
                            if markData.radarMark and markData.radarMark ~= 0 then SafeRemoveMark(markData.radarMark); markData.radarMark = nil end
                        end
                    end
                else
                    if not markData.IsCleanedUp then
                        SafeRemoveMark(markData.radarMark); markData.radarMark = nil
                        SafeRemoveMark(markData.hpMark); markData.hpMark = nil
                        SafeRemoveMark(markData.distMark); markData.distMark = nil
                        markData.IsCleanedUp = true
                    end
                end
            end
        end

        if _G.BNTMODConfig.Esp7 then
            pcall(function()
                local MyHUD = Cached_MyHUD
                if Valid(MyHUD) then
                    local totalEnemy = realCount + aiCount
                    if totalEnemy > 0 then
                        local text = string.format("ENEMY (P: %d | B: %d)", realCount, aiCount)
                        MyHUD:AddDebugText(text, localPlayer, 1.2, {X=0, Y=0, Z=150}, {X=0, Y=0, Z=150}, {R=255, G=255, B=255, A=255}, true, false, true, nil, 1.0, true)
                    else
                        MyHUD:AddDebugText("( CLEAR ENEMY VIP )", localPlayer, 1.2, {X=0, Y=0, Z=150}, {X=0, Y=0, Z=150}, {R=0, G=255, B=0, A=255}, true, false, true, nil, 1.0, true)
                end                              -- ✅ if totalEnemy ကို ပိတ်
        end                                  -- ✅ if Valid(MyHUD) ကို ပိတ်
    end)                                     -- ✅ pcall function ကို ပိတ်
end

        if _G.BNTMODConfig.EspStatic then
            pcall(function()
                local MyHUD = Cached_MyHUD
                if not Valid(MyHUD) then return end

                -- ESP ENEMY COUNT
                if _G.BNTMODConfig.EspEnemyCount then
                    local function GetRainbowColor()
                        local time = os.clock()
                        local r = math.sin(time * 0.8) * 0.5 + 0.5
                        local g = math.sin(time * 0.8 + 2.094) * 0.5 + 0.5
                        local b = math.sin(time * 0.8 + 4.188) * 0.5 + 0.5
                        return { R = math.floor(r * 255), G = math.floor(g * 255), B = math.floor(b * 255), A = 255 }
                    end

                    local myTeamId = localPlayer.TeamID or localPlayer:GetTeamID() or 0
                    local myPos = localPlayer:K2_GetActorLocation()
                    local maxDist = 35000
                    local realCount = 0
                    local aiCount = 0

                    for _, tPawn in pairs(allCharacters) do
                        if slua.isValid(tPawn) and tPawn ~= localPlayer then
                            local targetTeamId = tPawn.TeamID or tPawn:GetTeamID() or 0
                            if targetTeamId ~= myTeamId then
                                local enemyPos = tPawn:K2_GetActorLocation()
                                if enemyPos then
                                    local dx = enemyPos.X - myPos.X
                                    local dy = enemyPos.Y - myPos.Y
                                    local dz = enemyPos.Z - myPos.Z
                                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                                    if dist <= maxDist then
                                        local isAI = false
                                        if tPawn.bIsAI == true or tPawn.IsAI == true then isAI = true end
                                        if not isAI then
                                            local pState = tPawn.PlayerState or (type(tPawn.GetPlayerState) == "function" and tPawn:GetPlayerState())
                                            if slua.isValid(pState) then
                                                if pState.bIsABot == true or pState.bIsBot == true then isAI = true end
                                                local playerID = pState.PlayerId or pState.PlayerID
                                                if playerID and (playerID == 0 or playerID < 10000) then isAI = true end
                                                local exactPing = pState.ExactPing or pState.Ping
                                                if exactPing and exactPing == 0 then isAI = true end
                                            else isAI = true end
                                        end
                                        if isAI then aiCount = aiCount + 1 else realCount = realCount + 1 end
                                    end
                                end
                            end
                        end
                    end

                    local color = GetRainbowColor()
                    local totalEnemy = realCount + aiCount
                    local text = totalEnemy > 0 and string.format("❮ ENEMY : %d ❯", totalEnemy) or " ❮ CLEAR ENEMY || @GFEyollo❯"
                    MyHUD:AddDebugText(text, localPlayer, 1.05, {X=0, Y=0, Z=200}, {X=0, Y=0, Z=200}, color, true, false, true, nil, 1.2, true)
                end

                -- ESP WEAPON & STATUS ENEMY
                if _G.BNTMODConfig.EspWeaponStatus then
                    local ui_util = require("client.common.ui_util")
                    local viewportSize = ui_util and ui_util.GetViewportSize()
                    if viewportSize then
                        local centerX = viewportSize.X * 0.5
                        local centerY = viewportSize.Y * 0.5
                        local FOV_RADIUS = (10 / 100.0) * (viewportSize.X / 2.0)
                        local FVector2D = import("Vector2D")
                        local bestTarget = nil
                        local bestDist = 999999

                        for _, enemy in pairs(allCharacters) do
                            if Valid(enemy) and enemy ~= localPlayer and enemy.TeamID ~= localPlayer.TeamID then
                                local ePos = enemy:K2_GetActorLocation()
                                if ePos then
                                    local screen = FVector2D()
                                    if pc:ProjectWorldLocationToScreen(ePos, screen, false) and screen.X > 0 and screen.Y > 0 then
                                        local dx = screen.X - centerX
                                        local dy = screen.Y - centerY
                                        local distScreen = math.sqrt(dx*dx + dy*dy)
                                        if distScreen <= FOV_RADIUS then
                                            local dist3D = localPlayer:GetDistanceTo(enemy)
                                            if dist3D < bestDist then
                                                bestDist = dist3D
                                                bestTarget = enemy
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        if Valid(bestTarget) then
                            local distM = math.floor(bestDist / 100)
                            local hp = bestTarget.Health or 100
                            local maxHp = bestTarget.HealthMax or 100
                            local hpPercent = maxHp > 0 and math.floor((hp / maxHp) * 100) or 0
                            local isKnock = (hp <= 0 or bestTarget.HealthStatus == 1)
                            
                            local weaponName = "Bare Hands"
                            local eWeapon = nil
                            if bestTarget.CurrentWeapon then eWeapon = bestTarget.CurrentWeapon
                            elseif type(bestTarget.GetCurrentWeapon) == "function" then eWeapon = bestTarget:GetCurrentWeapon()
                            elseif bestTarget.WeaponManagerComponent then eWeapon = bestTarget.WeaponManagerComponent.CurrentWeaponReplicated end
                            if Valid(eWeapon) and type(eWeapon.GetWeaponName) == "function" then weaponName = eWeapon:GetWeaponName() end

                            local statusText = isKnock and " [K]" or ""
                            local text = string.format("%s | %dm | %d%% HP%s", weaponName, distM, hpPercent, statusText)
                            MyHUD:AddDebugText(text, bestTarget, 0.15, {X=0, Y=0, Z=-50}, {X=0, Y=0, Z=-50}, C_YELLOW, true, false, true, nil, 0.8, true)
                        end
                    end
                end
            end)
        end
    end)
end

_G.BNTMODState.LoopToken = (_G.BNTMODState.LoopToken or 0) + 1 
local myToken = _G.BNTMODState.LoopToken

local function FastTick() 
    if isExpired then 
        if not _G.BNTMODNotifiedExpire then
            Notify("MOD HAS EXPIRED! PLEASE CONTACT ADMIN TO RENEW!\nTelegram @GFEyollo")
            _G.BNTMODNotifiedExpire = true
        end
        return 
    end
    if myToken ~= _G.BNTMODState.LoopToken then return end
    pcall(MainLoop) 
    local okTicker, ticker = pcall(require, "common.time_ticker") 
    if okTicker and ticker and ticker.AddTimerOnce then 
        ticker.AddTimerOnce(LOOP_INTERVAL, FastTick)
    end 
end

local aimbotToken = 0
local function FastAimbotTick()
    if isExpired then return end
    if aimbotToken ~= _G.BNTMODState.AimbotLoopToken then return end
    pcall(function()
        if _G.BNTMODConfig.AimTouchEnable then _G.AimTouch() end
    end)
    local okTicker, ticker = pcall(require, "common.time_ticker")
    if okTicker and ticker and ticker.AddTimerOnce then
        ticker.AddTimerOnce(AIMBOT_INTERVAL, FastAimbotTick)
    end
end

if not isExpired then
    FastTick() 
    _G.BNTMODState.AimbotLoopToken = (_G.BNTMODState.AimbotLoopToken or 0) + 1
    aimbotToken = _G.BNTMODState.AimbotLoopToken
    local okTicker, ticker = pcall(require, "common.time_ticker")
    if okTicker and ticker and ticker.AddTimerOnce then
        ticker.AddTimerOnce(0.1, FastAimbotTick)
    end
    Notify("Contact @GFEyollo")
else
    FastTick() 
end

local function InitAllModSystems()
    if isExpired then return end 
    local GameplayData = package.loaded["GameLua.GameCore.Data.GameplayData"] or require("GameLua.GameCore.Data.GameplayData")
    if not GameplayData then return end
    pcall(function()
        local LocalPlayer = GameplayData.GetPlayerCharacter and GameplayData.GetPlayerCharacter()
        if slua.isValid(LocalPlayer) then
            if LocalPlayer.bHasShownDevNotice == nil then
                LocalPlayer.bHasShownDevNotice = false 
                LocalPlayer.bHasShownExpiredNotice = false 
                LocalPlayer.bIsDeadFlag = false
            end
        end
    end)
end

if not isExpired then
    pcall(function() require("common.time_ticker").AddTimerOnce(0.5, InitAllModSystems) end)
end

local class = require("class")
local CCharacterBase = require("GameLua.GameCore.Framework.CharacterBase")
local CBRPlayerCharacterBase = class(CCharacterBase, nil, BRPlayerCharacterBase)
return require("combine_class").DeclareFeature(CBRPlayerCharacterBase, {
  { SkyTransition = "GameLua.Mod.BaseMod.Gameplay.Feature.SkyControl.PlayerCharacterSkyTransitionFeature" },
  { CarryDeadBoxFeature = "GameLua.Mod.Library.GamePlay.Feature.CarryDeadBoxFeature" },
  { SpecialSuitFeature = "GameLua.Mod.Library.GamePlay.Feature.SpecialSuitFeature" },
  { TeleportPawnFeature = "GameLua.Mod.Library.GamePlay.Feature.TeleportPawnFeature" },
  { LifterControl = "GameLua.Mod.BaseMod.Gameplay.Feature.Player.CharacterLifterControlFeature" },
  { FinalKillEffect = "GameLua.Mod.BaseMod.Gameplay.Feature.Player.PlayerCharacterFinalKillEffectFeature" },
  { CampFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.Camp.PlayerCharacterCampFeature" },
  { BuildSkateFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.PlayerCharacterBuildVehicleFeature" },
  { CommonBornlandTransformFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.HeroPropFeature.CommonBornlandTransformFeature" },
  { ParachuteFormation = "GameLua.Mod.BaseMod.GamePlay.Feature.ParachuteFormationFeature" }
}, "BRPlayerCharacterBase")