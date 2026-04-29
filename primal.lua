-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

-- // Variables
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local RAnimFolder = RemotesFolder:WaitForChild("Animations")

-- remote/bindable references for animation and footstep replication
local pAnimationC : BindableEvent = RAnimFolder:WaitForChild("pAnimationC")
local gAnimationC : BindableFunction = RAnimFolder:WaitForChild("gAnimationC")

local FootstepsRemotes = RemotesFolder:WaitForChild("Footsteps")
local AddFootstep : RemoteEvent = FootstepsRemotes:WaitForChild("AddFootstep")
local FootstepService = require(ReplicatedStorage.Modules.Services.FootstepService)

local Camera = workspace.CurrentCamera

-- // Handler
local MovementController = {
    settings = {
        KeyBind = Enum.KeyCode.LeftShift,
        RunSpeed = 20,
        WalkSpeed = 12,
        HurtSpeed = 8,
        HurtTHold = 50,
        TweenTime = 1,
        Stamina = 100,
        StaminaTick = os.clock(),
        Climbing = false,
        ClimbDistance = 5,
        ClimbSpeed = 3,
        StickDistanceMax = 2,
        StickDistanceMin = 1,
        StickOffset = 1.5,
        DefaultFOV = 70,
        RunFOV = 85
    }
}
MovementController.__index = MovementController

-- constructor: initializes the character's movement states and sets up input binds
function MovementController.new(Character : Model)
    local self = setmetatable({}, MovementController)

    -- explicitly define base states
    self.Climbing = false
    self.Walking = false
    self.Running = false

    self.Player = Players.LocalPlayer
    self.Character = Character
    self.Humanoid = Character:WaitForChild("Humanoid")
    self.RootPart = Character:WaitForChild("HumanoidRootPart")
    self.Head = Character:WaitForChild("Head")

    -- clean up any default sounds from the root part to prevent audio overlap with our custom system
    for _,v in self.RootPart:GetChildren() do 
        if v:IsA("Sound") then v:Destroy() end 
    end
    self.RootPart.ChildAdded:Connect(function(child) 
        if child:IsA("Sound") then child:Destroy() end 
    end)

    -- we remove the default animate script to take full manual control over the character's rig
    self.Character:WaitForChild("Animate"):Destroy()

    self.Running = false
    self.Walking = true
    self.Status = false

    -- sprint Input Handling
    self.RunBind = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if gameProcessedEvent then return end
        
        -- prevent running if we are climbing or restricted by an external attribute
        if input.KeyCode == self.settings.KeyBind and not self.Climbing and not self.Character:GetAttribute("Balancing") then
            self.Running = true
            self.Walking = false

            -- smoothly transition speed and camera FOV for game feel
            TweenService:Create(self.Humanoid, TweenInfo.new(self.settings.TweenTime), {WalkSpeed = self.settings.RunSpeed}):Play()
            TweenService:Create(Camera, TweenInfo.new(self.settings.TweenTime), {FieldOfView = self.settings.RunFOV}):Play()
        end
    end)

    self.WalkBind = UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
        if input.KeyCode == self.settings.KeyBind and not self.Climbing then
            self.Running = false
            self.Walking = true

            TweenService:Create(self.Humanoid, TweenInfo.new(self.settings.TweenTime * 0.25), {WalkSpeed = self.settings.WalkSpeed}):Play()
            TweenService:Create(Camera, TweenInfo.new(self.settings.TweenTime * 0.25), {FieldOfView = self.settings.DefaultFOV}):Play()
        end
    end)

    -- // Animations Integration
    self.RunTrack = gAnimationC:Invoke("Run")
    self.WalKTrack = gAnimationC:Invoke("Walk")
    self.JumpTrack = gAnimationC:Invoke("Jump")
    self.IdleTrack = gAnimationC:Invoke("Idle")

    self.IdleTrack:Play()

    local footsteptick = os.clock()

    -- utilizing animation markers to sync footstep sounds/VFX perfectly with the animation timeline
    self.TemporaryStepConnectionW = self.WalKTrack:GetMarkerReachedSignal("Step"):Connect(function(param)
        local leg = param == "1" and self.Character["Left Leg"] or param == "2" and self.Character["Right Leg"] or nil

        if leg and os.clock() - footsteptick > 0.25 then
            footsteptick = os.clock()
            FootstepService:CreateFootstep(leg.Position, leg)
            AddFootstep:FireServer(leg) -- Replicate to other clients
        end
    end)

    self.TemporaryStepConnectionR = self.RunTrack:GetMarkerReachedSignal("Step"):Connect(function(param)
        local leg = param == "1" and self.Character["Right Leg"] or param == "2" and self.Character["Left Leg"] or nil

        if leg and os.clock() - footsteptick > 0.25 then
            footsteptick = os.clock()
            FootstepService:CreateFootstep(leg.Position, leg)
            AddFootstep:FireServer(leg)
        end
    end)

    -- core animation loop checking RootPart velocity to determine which track should be playing
    self.AnimationUpdate = RunService.RenderStepped:Connect(function(deltaTime)
        local velocity = self.RootPart.Velocity
        local speed = velocity.Magnitude

        if speed > 0.25 then
            if self.Running then
                if not self.RunTrack.IsPlaying then self.RunTrack:Play(0.5) end
                self.WalKTrack:Stop(0.25)
            elseif self.Walking then
                if not self.WalKTrack.IsPlaying then self.WalKTrack:Play(0.5) end
                self.RunTrack:Stop(0.25)
            else
                self.RunTrack:Stop(0.25)
                self.WalKTrack:Stop(0.25)
            end
        else
            self.RunTrack:Stop(0.25)
            self.WalKTrack:Stop(0.25)
        end
    end)

    self.Humanoid.StateChanged:Connect(function(old, new)
        if new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall and not self.Climbing then 
            self.JumpTrack:Play()
        else 
            self.JumpTrack:Stop(0.25)
        end
    end)

    -- // Climbing Mechanics Setup
    self.rayParams = RaycastParams.new()
    self.rayParams.FilterType = Enum.RaycastFilterType.Exclude
    self.rayParams.FilterDescendantsInstances = {self.Character}

    self.ClimbTrack = gAnimationC:Invoke("Climb")
    self.GrabTrack = gAnimationC:Invoke("LedgeGrab")
    self.BackflipTrack = gAnimationC:Invoke("BackflipClimb")

    self.ClimbStamina = 100

    self.ClimbUpdate = RunService.RenderStepped:Connect(function(deltaTime)
        self:Update(deltaTime)
    end)

    -- handle jump input contextually (normal jump vs wall eject)
    self.ClimbInput = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if gameProcessedEvent then return end
        if input.KeyCode == Enum.KeyCode.Space then
            local canClimb : boolean, canGrab : boolean, raycastResult : RaycastResult = self:CanClimb()

            if canClimb and not self.Climbing and self.ClimbStamina > 0 then
                self:StartClimb()
            elseif self.Climbing then
                self:ClimbJump(raycastResult)
            end
        end
    end)

    return self
end

-- casts a ray directly in front of the RootPart to detect climbable walls
function MovementController:CheckRay(Position)
    local direction = self.RootPart.CFrame.LookVector
    return workspace:Raycast(Position, direction * self.settings.ClimbDistance, self.rayParams)
end

-- custom raycast for specific vectors (like checking downwards for the ground)
function MovementController:IndependentCheckRay(Position, direction)
    local dir = direction or self.RootPart.CFrame.LookVector
    return workspace:Raycast(Position, dir, self.rayParams)
end

-- fires multiple raycasts to ensure the player's full body is aligned with a wall
function MovementController:GetRaycasts()
    local BodyRaycastResult = self:CheckRay(self.RootPart.Position)
    local HeadRaycastResult = self:CheckRay(self.Head.Position + Vector3.new(0, 2.5, 0))
    local NeckRaycastResult = self:CheckRay(self.Head.Position + Vector3.new(0, -1, 0))
    local BottomRaycastResult = self:IndependentCheckRay(self.RootPart.Position, Vector3.new(0, -5, 0))

    return BodyRaycastResult, HeadRaycastResult, NeckRaycastResult, BottomRaycastResult
end

-- evaluate raycast data to see if climbing or ledge grabbing is okay
function MovementController:CanClimb()
    local BodyRaycastResult, HeadRaycastResult, NeckRaycastResult, BottomRaycastResult = self:GetRaycasts()

    if BodyRaycastResult and HeadRaycastResult and NeckRaycastResult and not BottomRaycastResult then
        return true, false, BodyRaycastResult
    elseif BodyRaycastResult then
        return false, true, BodyRaycastResult
    end
end

-- transitions the character into the climbing state using modern constraints
function MovementController:StartClimb()
    if self.Climbing then return end
    self.Climbing = true
    self.ClimbTrack:Play(0.25)

    _G.ShiftLockModule:Disable()
    self.Humanoid.AutoRotate = false

    -- normalize walkspeed to prevent jittering during the physics transition
    TweenService:Create(self.Humanoid, TweenInfo.new(self.settings.TweenTime * 0.25), {WalkSpeed = self.settings.WalkSpeed}):Play()
    self.JumpTrack:Stop()

    -- Using modern AlignOrientation and LinearVelocity instead of deprecated BodyMovers
    self.ClimbAttachment = Instance.new("Attachment")
    self.ClimbAttachment.Name = "ClimbAttachment"
    self.ClimbAttachment.Parent = self.RootPart

    self.LinearVelocity = Instance.new("LinearVelocity")
    self.LinearVelocity.Name = "ClimbVelocity"
    self.LinearVelocity.Attachment0 = self.ClimbAttachment
    self.LinearVelocity.MaxForce = math.huge
    self.LinearVelocity.VectorVelocity = Vector3.zero
    self.LinearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
    self.LinearVelocity.Parent = self.RootPart

    self.AlignOrientation = Instance.new("AlignOrientation")
    self.AlignOrientation.Name = "ClimbOrientation"
    self.AlignOrientation.Attachment0 = self.ClimbAttachment
    self.AlignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
    self.AlignOrientation.MaxTorque = math.huge
    self.AlignOrientation.Responsiveness = 200
    self.AlignOrientation.Parent = self.RootPart
end

-- returns the character back to a standard walking state and cleans up constraints
function MovementController:StopClimb()
    if not self.Climbing then return end
    self.Climbing = false
    self.ClimbTrack:Stop(0.25)

    _G.ShiftLockModule:Enable()
    self.Humanoid.AutoRotate = true
    self.Walking = true

    if self.LinearVelocity then self.LinearVelocity:Destroy() end
    if self.AlignOrientation then self.AlignOrientation:Destroy() end
    if self.ClimbAttachment then self.ClimbAttachment:Destroy() end
end

-- boosts the player up if they reach the top of a surface
function MovementController:GrabLedge()
    self:StopClimb()
    self.GrabTrack:Play()
    
    -- applying an impulse with AssemblyLinearVelocity to launch the player over the top
    self.RootPart.AssemblyLinearVelocity = Vector3.new(0, 35, 0) + self.RootPart.CFrame.LookVector * 20
end

-- main physics update loop for climbing, handled on RenderStepped
function MovementController:Update(dt)
    if not self.Climbing then
        if self.ClimbStamina < 100 then
            self.ClimbStamina += 15 * dt
        end
        return
    else
        self.ClimbStamina -= 20 * dt
        if self.ClimbStamina <= 0 then
            -- push the player off the wall when stamina rans out
            self.RootPart.AssemblyLinearVelocity -= self.RootPart.CFrame.LookVector * 50
            self:StopClimb()
        end
    end
    
    local canClimb : boolean, canGrab : boolean, raycastResult : RaycastResult = self:CanClimb()

    self.Running = false
    self.Walking = false

    -- dynamically map the climb animation playback speed to the player's actual velocity
    if self.LinearVelocity then
        self.ClimbTrack:AdjustSpeed(self.LinearVelocity.VectorVelocity.Magnitude / (self.settings.ClimbSpeed * 3))
    end

    -- process input and convert it into a target velocity
    if self.LinearVelocity then
        local MovementVelocity = Vector3.zero

        if UserInputService:IsKeyDown(Enum.KeyCode.W) then MovementVelocity += Vector3.new(0, self.settings.ClimbSpeed, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then MovementVelocity += Vector3.new(0, -self.settings.ClimbSpeed, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then MovementVelocity += -self.RootPart.CFrame.RightVector * self.settings.ClimbSpeed end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then MovementVelocity += self.RootPart.CFrame.RightVector * self.settings.ClimbSpeed end

        self.LinearVelocity.VectorVelocity = MovementVelocity
    end

    -- surface Verification and Edge Cases
    if raycastResult then
        local wallPos = raycastResult.Position
        local wallNormal = raycastResult.Normal
        local targetPos = wallPos + wallNormal * 3
        local lookAtCFrame = CFrame.new(targetPos, wallPos)

        -- utilize Dot Product to determine slope angle. Drop player if it's a ceiling/overhang
        local up = Vector3.new(0, 1, 0)
        if math.abs(wallNormal:Dot(up)) >= 0.7 then 
            self:StopClimb()
        end

        -- check if the player is too close to the ground and make them stop climbing
        local hit = workspace:Raycast(self.RootPart.Position, Vector3.new(0, -5, 0), self.rayParams)
        if hit then 
            self:StopClimb()
        end

        -- update the character's orientation to face the wall normal
        if self.AlignOrientation then
            self.AlignOrientation.CFrame = lookAtCFrame
        end

        -- snap the rootpart back to the stick offset if it drifts too far or clips into wall
        if raycastResult.Distance >= self.settings.StickDistanceMax or raycastResult.Distance <= self.settings.StickDistanceMin then
            local wallPosition = raycastResult.Position
            
            local newPosition = wallPosition + wallNormal * self.settings.StickOffset
            local lookAt = wallPosition
            local newCFrame = CFrame.new(newPosition, lookAt)

            self.RootPart.CFrame = newCFrame
        end
    end

    -- state management based on raycast validity
    if (not canClimb and not canGrab) then
        self:StopClimb()
    elseif canGrab then 
        self:GrabLedge()
    end
end

-- allows the player to eject themselves away from the wall
function MovementController:ClimbJump(raycastResult : RaycastResult)
    self:StopClimb()
    self.BackflipTrack:Play()

    -- we factor in the wall's normal vector to ensure they jump *away* from the surface
    self.RootPart.AssemblyLinearVelocity = Vector3.new(0, 20, 0) + raycastResult.Normal * 20
end

-- garbage collection to prevent memory leaks when the character dies or is replaced
function MovementController:clear()
    self:StopClimb()
    
    for key, value in pairs(self) do
        if typeof(value) == "RBXScriptConnection" then
            value:Disconnect()
        end
    end

    table.clear(self)
end

return MovementController
