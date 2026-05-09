-- Connected Discord-GitHub | Discord: crow_works | Roblox: imanthestranger

--[[
	FpsCamera - Advanced First-Person Camera System

	A first-person camera controller providing immersive procedural effects:
	head bobbing, mouse-driven sway, idle breathing, and landing impact.
	Uses spring physics for smooth damping, CFrame composition for layered
	camera transforms, and metatable OOP for clean architecture.

	Key technical concepts demonstrated:
	- Metatable-based OOP with __index and typed constructors
	- Semi-implicit Euler spring solver (physics simulation)
	- CFrame composition for procedural camera animation
	- Signal lifecycle management to prevent memory leaks
	- Luau strict type annotations throughout
]]

--=========================================================================
-- Type Definitions
-- Strict types for the spring solver and camera config leverage Luau's
-- type checker to catch misuse at edit-time rather than runtime.
--=========================================================================

type SpringState = {
	Position: number,
	Velocity: number,
	Target: number,
	Damping: number,
	Frequency: number,
}

type CameraConfig = {
	BobFrequency: number,
	BobAmplitudeX: number,
	BobAmplitudeY: number,
	SwayDamping: number,
	SwayFrequency: number,
	SwayScale: number,
	BreathFrequency: number,
	BreathAmplitude: number,
	LandingImpulse: number,
	BodyRotationStep: number,
	HeadOffsetY: number,
}

--=========================================================================
-- Services
--=========================================================================

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

--=========================================================================
-- Constants
--=========================================================================

local RENDER_STEP_NAME = "FpsCamera_Update"
-- Run one priority level after the default camera so we can modify its output
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- Head attachment names that identify accessories mounted on the head.
-- Used to determine which accessory parts to clone for shadow mirroring.
local HEAD_ATTACHMENTS: {[string]: boolean} = {
	FaceCenterAttachment = true,
	FaceFrontAttachment = true,
	HairAttachment = true,
	HatAttachment = true,
}

-- Humanoid states where body rotation should be suppressed
-- to prevent visual glitches during non-standard locomotion.
local INVALID_ROTATION_STATES: {[Enum.HumanoidStateType]: boolean} = {
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Dead] = true,
}

-- Mask vector to zero out Y, projecting directions onto the XZ plane.
local XZ_MASK = Vector3.new(1, 0, 1)

-- Tuned defaults for a natural first-person feel.
local DEFAULT_CONFIG: CameraConfig = {
	BobFrequency = 8,       -- Head bob oscillation speed (Hz)
	BobAmplitudeX = 0.03,   -- Horizontal sway magnitude (studs)
	BobAmplitudeY = 0.05,   -- Vertical bounce magnitude (studs)
	SwayDamping = 0.7,      -- Mouse sway spring damping ratio
	SwayFrequency = 15,     -- Mouse sway spring natural frequency
	SwayScale = 0.08,       -- Mouse delta to spring target multiplier
	BreathFrequency = 1.2,  -- Breathing oscillation speed (Hz)
	BreathAmplitude = 0.002, -- Breathing oscillation magnitude (radians)
	LandingImpulse = 0.4,   -- Downward spring kick on landing (studs/sec)
	BodyRotationStep = 0.15, -- Max lerp alpha for body-to-camera rotation
	HeadOffsetY = 0.33,     -- Eye position as fraction of head height
}

--=========================================================================
-- Spring Class
-- A critically-damped spring solver for smooth value interpolation.
-- Unlike linear lerp which produces robotic motion, springs naturally
-- overshoot and settle, creating organic-feeling transitions.
--=========================================================================

local Spring = {}

-- Damping < 1 = underdamped (bouncy) 1 = critically damped : > 1 = overdamped.
function Spring.new(frequency: number, damping: number): SpringState
	return {
		Position = 0,
		Velocity = 0,
		Target = 0,
		Damping = damping,
		Frequency = frequency,
	}
end

-- Advances the spring state by dt seconds using semi implicit euler integration
-- Semi implicit euler updates velocity first using current position, then updates
-- position using the NEW velocity this conserves energy better than explicit euler
-- (which uses old values for both) preventing springs from exploding at low FPS.
function Spring.step(spring: SpringState, dt: number): number
	local displacement = spring.Position - spring.Target
	local omega = spring.Frequency * 2 * math.pi

	-- Hooke's law. restoring force proportional to displacement (-omega^2 * x)
	-- Viscous damping, drag proportional to velocity (-2 * zeta * omega * v)
	local springForce = -omega * omega * displacement
	local dampingForce = -2 * spring.Damping * omega * spring.Velocity

	-- Semi implicit, velocity updated first, then position uses new velocity
	spring.Velocity += (springForce + dampingForce) * dt
	spring.Position += spring.Velocity * dt

	return spring.Position
end

-- Applies an instantaneous velocity impulse to the spring.
-- Used for one-shot effects like landing impacts where we want a sharp
-- reaction followed by natural spring settle behavior.
function Spring.impulse(spring: SpringState, force: number)
	spring.Velocity += force
end

--=========================================================================
-- FpsCamera Class
-- Uses __index metatable pattern for proper Luau OOP with inheritance
-- support and efficient method lookup via the prototype chain.
--=========================================================================

local FpsCamera = {}
FpsCamera.__index = FpsCamera

function FpsCamera.new()
	local self = setmetatable({
		_started = false,
		_config = table.clone(DEFAULT_CONFIG),
		_connections = {} :: {RBXScriptConnection},
		_renderStepBound = false,

		-- Spring instances for mouse sway (X/Y axes) and landing impact
		_swaySpringX = Spring.new(DEFAULT_CONFIG.SwayFrequency, DEFAULT_CONFIG.SwayDamping),
		_swaySpringY = Spring.new(DEFAULT_CONFIG.SwayFrequency, DEFAULT_CONFIG.SwayDamping),
		_landingSpring = Spring.new(12, 0.5), -- Stiff, slightly underdamped for a snappy settle

		-- Phase accumulators for periodic effects (head bob, breathing)
		_bobPhase = 0,
		_breathPhase = 0,
		_wasFreeFalling = false,

		-- Shadow mirror system
		_mirrorBin = nil :: Folder?,
		_headMirrors = {} :: {[BasePart]: BasePart},

		-- Character references cached on spawn for fast per-frame access
		_player = Players.LocalPlayer,
		_character = nil :: Model?,
		_humanoid = nil :: Humanoid?,
		_rootPart = nil :: BasePart?,
		_head = nil :: BasePart?,
	}, FpsCamera)

	return self
end

--=========================================================================
-- Connection Management
-- Tracks all RBXScriptConnections for bulk disconnect on cleanup,
-- preventing the common memory leak where listeners outlive their objects.
--=========================================================================

-- Connects a callback to a signal and registers it for automatic cleanup.
function FpsCamera:_connect(signal: RBXScriptSignal, callback: (...any) -> ...any): RBXScriptConnection
	local connection = signal:Connect(callback)
	table.insert(self._connections, connection)
	return connection
end

-- Disconnects and clears all tracked connections.
function FpsCamera:_disconnectAll()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

--=========================================================================
-- First-Person Detection
-- Measures the distance between camera origin and the focus point.
-- In first-person roblox moves the camera to the head making this
-- distance approach zero, a 1-stud threshold handles float imprecision.
--=========================================================================

function FpsCamera:IsInFirstPerson(): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	-- Scriptable cameras are manually controlled and never first-person
	if camera.CameraType == Enum.CameraType.Scriptable then
		return false
	end

	return (camera.Focus.Position - camera.CFrame.Position).Magnitude <= 1
end

--=========================================================================
-- Subject Position
-- Returns eye-level position by offsetting from the Head part.
-- The default camera targets HumanoidRootPart; we override to place
-- the viewpoint at approximately 1/3 from the top of the head.
--=========================================================================

function FpsCamera:GetSubjectPosition(): Vector3?
	local head = self._head
	local humanoid = self._humanoid

	if not (head and head:IsA("BasePart") and humanoid and humanoid.Health > 0) then
		return nil
	end

	-- CFrame multiplication applies the offset in the head's local space,
	-- so the eye position moves correctly regardless of head orientation.
	local eyeCF = head.CFrame * CFrame.new(0, head.Size.Y * self._config.HeadOffsetY, 0)
	return eyeCF.Position
end

--=========================================================================
-- Procedural Camera Effects
-- Each method returns a CFrame offset composed in the render loop.
-- Keeping effects separate allows independent tuning and toggling.
--=========================================================================

-- Head Bob: figure-8 motion pattern simulating bipedal locomotion.
-- Vertical uses 2x frequency (two bounces per stride), horizontal uses
-- 1x (one sway per stride). Amplitude scales with movement speed.
function FpsCamera:ComputeHeadBob(speed: number, dt: number): CFrame
	local cfg = self._config

	if speed < 0.5 then
		-- Smoothly decay phase to zero to avoid a jarring stop
		self._bobPhase *= 0.9
		return CFrame.identity
	end

	-- Speed factor maps walk/run speed to bob intensity, clamped to prevent strobing
	local speedFactor = math.clamp(speed / 16, 0.5, 2)
	self._bobPhase += dt * cfg.BobFrequency * speedFactor

	local bobY = math.sin(self._bobPhase * 2) * cfg.BobAmplitudeY * speedFactor
	local bobX = math.sin(self._bobPhase) * cfg.BobAmplitudeX * speedFactor

	return CFrame.new(bobX, bobY, 0)
end

-- Breathing, subtle pitch/roll oscillation during idle to add visual life.
-- Uses two sine waves at different frequencies to
-- avoid a repetitive looking loop pattern.
function FpsCamera:ComputeBreathing(dt: number): CFrame
	local cfg = self._config
	self._breathPhase += dt * cfg.BreathFrequency

	local pitch = math.sin(self._breathPhase) * cfg.BreathAmplitude
	local roll = math.sin(self._breathPhase * 0.7) * cfg.BreathAmplitude * 0.5

	return CFrame.Angles(pitch, 0, roll)
end

-- Mouse Sway, spring-driven inertia effect from mouse movement.
-- Raw mouse delta drives spring targets, the spring's natural overshoot
-- and settle produces a weighty, polished camera feel. Targets decay
-- each frame so the camera returns to neutral when the mouse stops.
function FpsCamera:ComputeMouseSway(dt: number): CFrame
	local cfg = self._config
	local delta = UserInputService:GetMouseDelta()

	-- Scale and clamp mouse input to a subtle range for spring targets
	self._swaySpringX.Target = math.clamp(delta.X * cfg.SwayScale, -0.2, 0.2)
	self._swaySpringY.Target = math.clamp(delta.Y * cfg.SwayScale, -0.2, 0.2)

	local swayX = Spring.step(self._swaySpringX, dt)
	local swayY = Spring.step(self._swaySpringY, dt)

	-- Decay targets toward zero so sway settles when mouse stops
	self._swaySpringX.Target *= 0.5
	self._swaySpringY.Target *= 0.5

	-- X mouse → Y rotation (yaw), Y mouse → X rotation (pitch),
	-- plus a subtle Z roll from horizontal movement for a natural feel
	return CFrame.Angles(-swayY * 0.3, -swayX * 0.3, swayX * 0.15)
end

-- Landing Impact: detects FreeFalling → grounded transition and fires
-- a spring impulse for a satisfying "camera dip and recover" effect.
function FpsCamera:ComputeLandingImpact(dt: number): CFrame
	local humanoid = self._humanoid

	if humanoid then
		local isFalling = (humanoid:GetState() == Enum.HumanoidStateType.Freefall)

		-- Impulse triggers on the exact frame we land
		if self._wasFreeFalling and not isFalling then
			Spring.impulse(self._landingSpring, self._config.LandingImpulse)
		end

		self._wasFreeFalling = isFalling
	end

	local offset = Spring.step(self._landingSpring, dt)
	return CFrame.new(0, -offset, 0)
end

--=========================================================================
-- Body Rotation
-- Roblox's default camera doesn't rotate the character body in first
-- person. We lerp the HumanoidRootPart toward the camera's XZ look
-- direction so the character faces where the player is looking.
-- Uses CFrame.lookAt for robust direction construction and frame-rate
-- independent lerp via dt-scaled alpha.
--=========================================================================

function FpsCamera:UpdateBodyRotation(dt: number)
	local rootPart = self._rootPart
	local humanoid = self._humanoid
	local camera = workspace.CurrentCamera

	if not (rootPart and humanoid and camera) then
		return
	end

	-- Suppress rotation during states that have their own orientation logic
	if INVALID_ROTATION_STATES[humanoid:GetState()] then
		return
	end

	-- VehicleSeats control their own occupant rotation
	if humanoid.Sit and humanoid.SeatPart and humanoid.SeatPart:IsA("VehicleSeat") then
		return
	end

	-- Project camera look vector onto XZ plane for horizontal-only rotation
	local flatLook = camera.CFrame.LookVector * XZ_MASK

	-- Guard against degenerate zero vector when looking straight up/down
	if flatLook.Magnitude < 0.001 then
		return
	end

	local pos = rootPart.Position
	local targetCF = CFrame.lookAt(pos, pos + flatLook.Unit)
	local step = math.min(self._config.BodyRotationStep, dt * 15)

	rootPart.CFrame = rootPart.CFrame:Lerp(targetCF, step)
end

--=========================================================================
-- Head Mirror System
-- In first-person the head is invisible, but this removes its shadow.
-- We clone head parts into a Folder and offset them along the light
-- direction: far enough to be off-screen, close enough for correct
-- shadow projection from the engine's shadow mapping system.
--=========================================================================

-- Gives the direction of the shadowcasting light source.
-- Returns moon direction when the sun is below the horizon.
function FpsCamera:GetShadowDirection(): Vector3
	local sunDir = Lighting:GetSunDirection()

	if sunDir.Y < -0.3 then
		return Lighting:GetMoonDirection()
	end

	return sunDir
end

-- Determines if a descendant belongs to the head region by checking
-- attachment names on accessory Handles, or if it's the Head part itself.
function FpsCamera:IsHeadPart(part: Instance): boolean
	-- Tools have their own visibility logic; skip them
	if part:FindFirstAncestorOfClass("Tool") then
		return false
	end

	if part:IsA("Decal") then
		part = part.Parent :: Instance
	end

	if not (part and part:IsA("BasePart")) then
		return false
	end

	local accessory = part:FindFirstAncestorWhichIsA("Accessory")

	if accessory then
		local handle: BasePart? = if part.Name == "Handle"
			then part :: BasePart
			else accessory:FindFirstChild("Handle", true) :: BasePart?

		if handle and handle:IsA("BasePart") then
			for _, child in handle:GetChildren() do
				if child:IsA("Attachment") and HEAD_ATTACHMENTS[child.Name] then
					return true
				end
			end
		end
	elseif part.Name == "Head" then
		local humanoid = if part.Parent then part.Parent:FindFirstChildOfClass("Humanoid") else nil
		local camera = workspace.CurrentCamera

		if humanoid and camera and camera.CameraSubject == humanoid then
			return true
		end
	end

	return false
end

-- Creates a lightweight mirror clone of a head BasePart for shadow casting.
-- Only visual sub-objects (meshes, decals) are cloned; physics properties
-- are disabled since the mirror only needs to cast a shadow silhouette.
function FpsCamera:AddHeadMirror(descendant: Instance)
	if not (descendant:IsA("BasePart") and self:IsHeadPart(descendant)) then
		return
	end

	local basePart = descendant :: BasePart
	local mirror = basePart:Clone()
	mirror:ClearAllChildren()
	mirror.Locked = true
	mirror.Anchored = true
	mirror.CanCollide = false
	mirror.CanQuery = false
	mirror.CanTouch = false
	mirror.Parent = self._mirrorBin

	-- Selectively mirror visual children and bind their mutable properties
	for _, child in basePart:GetChildren() do
		if child:IsA("DataModelMesh") then
			local copy = child:Clone()
			copy.Parent = mirror
			-- Sync mesh scale changes (e.g. character scaling)
			self:_connect(child:GetPropertyChangedSignal("Scale"), function()
				copy.Scale = child.Scale
			end)
		elseif child:IsA("Decal") then
			local copy = child:Clone()
			copy.Parent = mirror
			self:_connect(child:GetPropertyChangedSignal("Transparency"), function()
				copy.Transparency = child.Transparency
			end)
		end
	end

	self._headMirrors[basePart] = mirror

	-- Sync part transparency (head goes transparent in first-person)
	self:_connect(basePart:GetPropertyChangedSignal("Transparency"), function()
		mirror.Transparency = basePart.Transparency
	end)
end

-- Removes and destroys a mirror clone when the original part is removed.
function FpsCamera:RemoveHeadMirror(descendant: Instance)
	if not descendant:IsA("BasePart") then
		return
	end

	local mirror = self._headMirrors[descendant :: BasePart]
	if mirror then
		mirror:Destroy()
		self._headMirrors[descendant :: BasePart] = nil
	end
end

-- Positions mirrors along the shadow direction so they project correct
-- shadows. Hidden when shadows would be behind the camera.
function FpsCamera:UpdateMirrors(cameraCF: CFrame)
	if not self._mirrorBin then
		return
	end

	local shadowDir = self:GetShadowDirection()
	local inView = cameraCF.LookVector:Dot(shadowDir)

	if inView < 0 then
		for real, mirror in self._headMirrors do
			mirror.CFrame = real.CFrame + (shadowDir * 9)
		end
		self._mirrorBin.Parent = workspace.CurrentCamera
	else
		self._mirrorBin.Parent = nil
	end
end

--=========================================================================
-- Character Lifecycle
-- Rebuilds mirror clones and caches body part references on each spawn.
-- Uses task.spawn for WaitForChild calls to avoid blocking the caller.
--=========================================================================

function FpsCamera:OnCharacterAdded(character: Model)
	if self._mirrorBin then
		self._mirrorBin:ClearAllChildren()
		self._mirrorBin.Parent = nil
	end

	self._headMirrors = {}
	self._character = character
	self._humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid
	self._rootPart = character:WaitForChild("HumanoidRootPart", 10) :: BasePart
	self._head = character:WaitForChild("Head", 10) :: BasePart

	-- Build initial mirror set from all loaded descendants
	for _, desc in character:GetDescendants() do
		self:AddHeadMirror(desc)
	end

	-- Handle accessories equipped after initial load
	self:_connect(character.DescendantAdded, function(desc)
		self:AddHeadMirror(desc)
	end)

	self:_connect(character.DescendantRemoving, function(desc)
		self:RemoveHeadMirror(desc)
	end)

	self._wasFreeFalling = false
end

--=========================================================================
-- Core Render Loop
-- Bound at Camera priority + 1 so it runs immediately after Roblox's
-- default camera system. All procedural CFrame offsets are composed
-- via multiplication in a specific order:
--   1. Head position offset (translation)
--   2. Head bob (translation, speed-dependent)
--   3. Landing impact (translation, spring-driven)
--   4. Mouse sway (rotation, spring-driven)
--   5. Breathing (rotation, periodic)
-- Translation effects are applied before rotations so that rotational
-- effects pivot around the final camera position, not the pre-offset one.
--=========================================================================

function FpsCamera:_onRenderStep(dt: number)
	if not self:IsInFirstPerson() then
		if self._mirrorBin then
			self._mirrorBin.Parent = nil
		end
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local baseCF = camera.CFrame

	-- Reposition camera to eye level on the Head part
	local headPos = self:GetSubjectPosition()
	if headPos then
		local offset = headPos - baseCF.Position
		baseCF += offset
		camera.Focus += offset
	end

	-- Compute horizontal movement speed for speed-dependent effects.
	-- Uses AssemblyLinearVelocity (modern API) instead of deprecated .Velocity
	local speed = 0
	if self._rootPart then
		speed = (self._rootPart.AssemblyLinearVelocity * XZ_MASK).Magnitude
	end

	-- Compose all procedural offsets via CFrame multiplication
	local bob = self:ComputeHeadBob(speed, dt)
	local landing = self:ComputeLandingImpact(dt)
	local sway = self:ComputeMouseSway(dt)
	local breath = self:ComputeBreathing(dt)

	camera.CFrame = baseCF * bob * landing * sway * breath

	self:UpdateBodyRotation(dt)
	self:UpdateMirrors(camera.CFrame)
end

--=========================================================================
-- Public Lifecycle Methods
--=========================================================================

-- Initializes the camera system. Safe to call multiple times;
-- subsequent calls are no-ops due to the _started guard.
function FpsCamera:Start()
	if self._started then
		return
	end
	self._started = true

	self._mirrorBin = Instance.new("Folder")
	self._mirrorBin.Name = "FpsCameraMirrors"

	-- Bind render loop at camera priority + 1 to post-process default camera
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		self:_onRenderStep(dt)
	end)
	self._renderStepBound = true

	-- Toggle AutoRotate based on rotation mode; we handle rotation manually
	-- in first-person for smoother results than the engine default.
	self:_connect(UserGameSettings:GetPropertyChangedSignal("RotationType"), function()
		if self._humanoid then
			local isFP = (UserGameSettings.RotationType == Enum.RotationType.CameraRelative)
			self._humanoid.AutoRotate = not isFP
		end
	end)

	local character = self._player.Character
	if character then
		task.spawn(function()
			self:OnCharacterAdded(character)
		end)
	end

	self:_connect(self._player.CharacterAdded, function(char)
		self:OnCharacterAdded(char)
	end)
end

-- Full cleanup: disconnects all signals, unbinds render step,
-- destroys mirror clones. Safe to call multiple times.
function FpsCamera:Destroy()
	self:_disconnectAll()

	if self._renderStepBound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		self._renderStepBound = false
	end

	if self._mirrorBin then
		self._mirrorBin:Destroy()
		self._mirrorBin = nil
	end

	self._headMirrors = {}
	self._started = false
end

--=========================================================================
-- Module Export
-- Returns a singleton instance so consuming scripts can call
-- FpsCamera:Start() and FpsCamera:IsInFirstPerson() directly.
--=========================================================================

return FpsCamera.new()
