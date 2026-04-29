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

local pAnimationC : BindableEvent = RAnimFolder:WaitForChild("pAnimationC")
local gAnimationC : BindableFunction = RAnimFolder:WaitForChild("gAnimationC")

local FootstepsRemotes = RemotesFolder:WaitForChild("Footsteps")
local AddFootstep : RemoteEvent = FootstepsRemotes:WaitForChild("AddFootstep")
local FootstepService = require(ReplicatedStorage.Modules.Services.FootstepService)

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
        StaminaTick = tick(),
        Climbing = false,
        ClimbDistance = 5,
        ClimbSpeed = 3,
        StickDistanceMax = 2,
        StickDistanceMin = 1,
        StickOffset = 1.5
    }
}
MovementController.__index = MovementController

function MovementController.new(Character : Model)
    local self = setmetatable({}, MovementController)

    -- // Disable all movement constants
    self.Climbing = false
    self.Walking = false
    self.Running = false

    self.Player = Players.LocalPlayer
    self.Character = Character
    self.Humanoid = Character:WaitForChild("Humanoid")
    self.RootPart = Character:WaitForChild("HumanoidRootPart")
    self.Head = Character:WaitForChild("Head")

    for _,v in self.RootPart:GetChildren() do if v:IsA("Sound") then v:Destroy() end end
    self.RootPart.ChildAdded:Connect(function(child) if child:IsA("Sound") then child:Destroy() end end)

    self.Character:WaitForChild("Animate"):Destroy()

    -- // Running and Walking

    self.Running = false
    self.Walking = true
    self.Status = false

    self.RunBind = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if gameProcessedEvent then return end
        if input.KeyCode == self.settings.KeyBind and not self.Climbing and not self.Character:GetAttribute("Balancing") then
            self.Running = true; self.Walking = false

            TweenService:Create(self.Humanoid, TweenInfo.new(self.settings.TweenTime), {WalkSpeed = self.settings.RunSpeed}):Play()
        end
    end)

    self.WalkBind = UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
        if input.KeyCode == self.settings.KeyBind and not self.Climbing then
            self.Running = false; self.Walking = true

            TweenService:Create(self.Humanoid, TweenInfo.new(self.settings.TweenTime * 0.25), {WalkSpeed = self.settings.WalkSpeed}):Play()
        end
    end)

    -- // Animations

    self.RunTrack = gAnimationC:Invoke("Run")
    self.WalKTrack = gAnimationC:Invoke("Walk")
    self.JumpTrack = gAnimationC:Invoke("Jump")
    self.IdleTrack = gAnimationC:Invoke("Idle")

    self.IdleTrack:Play()

    local footsteptick = tick()

    self.TemporaryStepConnectionW = self.WalKTrack:GetMarkerReachedSignal("Step"):Connect(function(param)
        local leg = param == "1" and self.Character["Left Leg"] or param == "2" and self.Character["Right Leg"] or nil

        if leg and tick() - footsteptick > 0.25 then
            footsteptick = tick()
            FootstepService:CreateFootstep(leg.Position, leg)
            AddFootstep:FireServer(leg)
        end
    end)

    self.TemporaryStepConnectionR = self.RunTrack:GetMarkerReachedSignal("Step"):Connect(function(param)
        local leg = param == "1" and self.Character["Right Leg"] or param == "2" and self.Character["Left Leg"] or nil

        if leg and tick() - footsteptick > 0.25 then
            footsteptick = tick()
            FootstepService:CreateFootstep(leg.Position, leg)
            AddFootstep:FireServer(leg)
        end
    end)

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

    self.Humanoid.StateChanged:Connect(function(old,new)
        if new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall and not self.Climbing then warn("Jump")
            self.JumpTrack:Play()
        else warn("Not jumping")
            self.JumpTrack:Stop(0.25)
        end
    end)

    -- // Climbing

    self.rayParams = RaycastParams.new()
    self.rayParams.FilterType = Enum.RaycastFilterType.Blacklist
    self.rayParams.FilterDescendantsInstances = {self.Character}

    -- animations
    self.ClimbTrack = gAnimationC:Invoke("Climb")
    self.GrabTrack = gAnimationC:Invoke("LedgeGrab")
    self.BackflipTrack = gAnimationC:Invoke("BackflipClimb")

    self.ClimbStamina = 100

    function self:CheckRay(Position)
        local direction = self.RootPart.CFrame.LookVector
        return workspace:Raycast(Position, direction * self.settings.ClimbDistance, self.rayParams)
    end

    function self:IndependentCheckRay(Position, direction)
        local direction = direction or self.RootPart.CFrame.LookVector
        return workspace:Raycast(Position, direction, self.rayParams)
    end

    function self:GetRaycasts()
        local BodyRaycastResult = self:CheckRay(self.RootPart.Position)
        local HeadRaycastResult = self:CheckRay(self.Head.Position + Vector3.new(0, 2.5, 0))
        local NeckRaycastResult = self:CheckRay(self.Head.Position + Vector3.new(0, -1, 0))
        local BottomRaycastResult = self:IndependentCheckRay(self.RootPart.Position, Vector3.new(0, -5, 0))

        return BodyRaycastResult, HeadRaycastResult, NeckRaycastResult, BottomRaycastResult
    end

    function self:CanClimb()
        local BodyRaycastResult, HeadRaycastResult, NeckRaycastResult, BottomRaycastResult = self:GetRaycasts()

        if BodyRaycastResult and HeadRaycastResult and NeckRaycastResult and not BottomRaycastResult then
            return true, false, BodyRaycastResult
        elseif BodyRaycastResult then
            return false, true, BodyRaycastResult
        end
    end

    function self:StartClimb()
        if self.Climbing then return end
        self.Climbing = true
        self.ClimbTrack:Play(0.25)

        -- Stop Autorotate
        _G.ShiftLockModule:Disable()
        self.Humanoid.AutoRotate = false

        -- Change walkspeed to default walkspeed
        TweenService:Create(self.Humanoid, TweenInfo.new(self.settings.TweenTime * 0.25), {WalkSpeed = self.settings.WalkSpeed}):Play()

        -- Stop JumpTrack incase it is playing.
        self.JumpTrack:Stop()

        -- Add body velocity for movement
        self.BodyVelocity = Instance.new("BodyVelocity")
        self.BodyVelocity.Name = "ClimbVelocity"
        self.BodyVelocity.Parent = self.RootPart
        self.BodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
        self.BodyVelocity.Velocity = Vector3.zero

        -- Add gyro to keep body aligned with surface
        self.BodyGyro = Instance.new("BodyGyro")
        self.BodyGyro.MaxTorque = Vector3.new(100000, 100000, 100000)
        self.BodyGyro.P = 10000
        self.BodyGyro.Parent = self.RootPart
    end

    function self:StopClimb()
        if not self.Climbing then return end
        self.Climbing = false
        self.ClimbTrack:Stop(0.25)

        -- Resume Autorotate
        _G.ShiftLockModule:Enable()
        self.Humanoid.AutoRotate = true

        -- Continue walking animation
        self.Walking = true

        if self.BodyVelocity then
            self.BodyVelocity:Destroy()
        end

        if self.BodyGyro then
            self.BodyGyro:Destroy()
        end
    end

    function self:GrabLedge()
        self:StopClimb()

        self.GrabTrack:Play()

        self.GrabVelocity = Instance.new("BodyVelocity")
        self.GrabVelocity.Name = "GrabVelocity"
        self.GrabVelocity.Parent = self.RootPart
        self.GrabVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
        self.GrabVelocity.Velocity = Vector3.new(0, 35, 0) + self.RootPart.CFrame.lookVector * 20

        Debris:AddItem(self.GrabVelocity, 0.1)
    end

    function self:Update(dt)
        if not self.Climbing then
            if self.ClimbStamina < 100 then
                self.ClimbStamina += 15 * dt
            end
            return
        else
            ---warn(self.ClimbStamina)
            self.ClimbStamina -= 20 * dt
            if self.ClimbStamina <= 0 then
                self.RootPart.Velocity -= self.RootPart.CFrame.LookVector * 50
                self:StopClimb()
            end
        end
        local canClimb : boolean, canGrab : boolean, raycastResult : RaycastResult = self:CanClimb()

        -- Stop other animations

        self.Running = false
        self.Walking = false

        -- Update climbtrack speed

        self.ClimbTrack:AdjustSpeed(self.BodyVelocity.Velocity.Magnitude / (self.settings.ClimbSpeed * 3))

        -- Movement

        if self.BodyVelocity then
            local MovementVelocity = Vector3.zero

            if UserInputService:IsKeyDown(Enum.KeyCode.W) then
                MovementVelocity += Vector3.new(0,self.settings.ClimbSpeed,0)
            end
    
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then
                MovementVelocity += Vector3.new(0,-self.settings.ClimbSpeed,0)
            end
    
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then
                MovementVelocity += -self.RootPart.CFrame.RightVector * self.settings.ClimbSpeed
            end
    
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then
                MovementVelocity += self.RootPart.CFrame.RightVector * self.settings.ClimbSpeed
            end

            self.BodyVelocity.Velocity = MovementVelocity
        end

        -- Checks

        if raycastResult then
            -- // Make sure surface is valid, if not then stop.
            local wallPos = raycastResult.Position
            local wallNormal = raycastResult.Normal
            local targetPos = wallPos + wallNormal * 3
            local lookAtCFrame = CFrame.new(targetPos, wallPos)
    
            -- invalid surface
            local up = Vector3.new(0, 1, 0)
            if math.abs(wallNormal:Dot(up)) >= 0.7 then -- roof/ceiling
                self:StopClimb()
            end

            -- near ground

            local Ray = Ray.new(self.RootPart.Position, Vector3.new(0,-5,0))
            local hit, position = workspace:FindPartOnRayWithIgnoreList(Ray, {self.Character})

            if hit then -- we are near the ground
                self:StopClimb()
            end

            -- // Add BodyGyro to rotate to face wall

            if self.BodyGyro then
                self.BodyGyro.CFrame = lookAtCFrame
            end

            -- // If surface is too far, we'll stick our character again

            if raycastResult.Distance >= self.settings.StickDistanceMax or raycastResult.Distance <= self.settings.StickDistanceMin then
                local wallPosition = raycastResult.Position
                local wallNormal = raycastResult.Normal
        
                local newPosition = wallPosition + wallNormal * self.settings.StickOffset
                local lookAt = wallPosition
                local newCFrame = CFrame.new(newPosition, lookAt)

                self.RootPart.CFrame = newCFrame
            end
        end
        
        if (not canClimb and not canGrab) then
            self:StopClimb()
        elseif canGrab then warn("Ledge!")
            self:GrabLedge()
        end
    end

    function self:ClimbJump(raycastResult : RaycastResult)
        self:StopClimb()

        self.BackflipTrack:Play()

        -- // Backflip Velocity
        local wallJump = Instance.new("BodyVelocity")
        wallJump.MaxForce = Vector3.new(1, 1, 1) * 50000
        wallJump.Velocity = Vector3.new(0, 20, 0) + raycastResult.Normal * 20
        wallJump.Parent = self.RootPart

        -- // Delete BodyVelocity
        Debris:AddItem(wallJump, 0.15)
    end

    self.ClimbUpdate = RunService.RenderStepped:Connect(function(deltaTime)
        self:Update(deltaTime)
    end)

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

function MovementController:clear()
    for key, value in pairs(self) do
        if typeof(value) == "RBXScriptConnection" then
            value:Disconnect()
        end
    end

    table.clear(self)
end

return MovementController
