-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

-- // Variables
local LocalPlayer = Players.LocalPlayer
local LPCamera = workspace.CurrentCamera

local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local InventoryRemotes = RemotesFolder:WaitForChild("Inventory")
local GetInfo: RemoteFunction = InventoryRemotes:WaitForChild("GetInfo")
local AddItem: RemoteEvent = InventoryRemotes:WaitForChild("AddItem")
local RemoveItem: RemoteEvent = InventoryRemotes:WaitForChild("RemoveItem")

local InventoryMFolder = script.Parent
local ItemData = require(InventoryMFolder:WaitForChild("ItemData"))
local Utility = require(InventoryMFolder:WaitForChild("InventoryUtility"))

local UIFolder = ReplicatedStorage:WaitForChild("UI")
local InventoryUI = UIFolder:WaitForChild("Inventory")

-- // Handler Module
local InventoryHandler = {
    Inventory = {},
    KeyBind = Enum.KeyCode.G,
    UI = InventoryUI,
    UIEnabled = false,
    LastPressed = 0,
    Cooldown = 1,
    
    -- Dragging State
    MainSelected = nil,
    SelectedUI = nil,
    GrabUpdate = nil,
    
    -- Viewport State
    ViewportCamera = Instance.new("Camera"),
    RotationY = 0,
    DraggingViewport = false,
    LastMousePosition = Vector2.zero,
    ViewportCharacter = nil
}

-- // Core Initialization
function InventoryHandler:Initialize()
    self.Inventory = GetInfo:InvokeServer()
    self.UI.Parent = LocalPlayer:WaitForChild("PlayerGui")
    self.UI.Enabled = true -- Hide visual elements, keep UI active for inputs
    
    -- Give information to the inventory util
    Utility.UI = self.UI

    self:CacheUIElements()
    self:SetupViewport()
    self:SetupAnimations()
    self:SetupSlots()
    self:SetupNetwork()
    self:SetupInput()
    
    self:ToggleUI(false) -- Ensure UI starts hidden
end

-- // Method: Cache UI Elements
function InventoryHandler:CacheUIElements()
    self.SlotBG = self.UI:WaitForChild("SlotBG")
    self.ClothSlots = self.SlotBG:WaitForChild("ClothSlots")
    self.ClothMain = self.ClothSlots:WaitForChild("Main")
    self.CharacterPort = self.ClothMain:WaitForChild("CharacterPort")
    self.CharacterPortBG = self.ClothMain:WaitForChild("CharacterPortBG")
    
    self.ItemSlots = self.SlotBG:WaitForChild("ItemSlots")
    self.ItemSlotsMain = self.ItemSlots:WaitForChild("Main")
    self.Hotbar = self.ItemSlotsMain.Parent:WaitForChild("Hotbar")
    self.HotbarGrid = self.Hotbar:WaitForChild("UIGridLayout")
    self.UIBackground = self.UI:WaitForChild("Background")
    
    self.ClothSlotsPositionTB = {}
    for _, Slot in pairs(self.ClothSlots:GetChildren()) do
        if Slot:IsA("Frame") then
            self.ClothSlotsPositionTB[Slot] = {
                Position = Slot.Position,
                Size = Slot.Size
            }
        end
    end
end

-- // Method: Setup Viewport
function InventoryHandler:SetupViewport()
    self.ViewportCamera.FieldOfView = 80
    self.CharacterPort.CurrentCamera = self.ViewportCamera
    
    -- Clone Character ONCE, not on a loop
    local function LoadCharacter(character)
        if self.ViewportCharacter then
            self.ViewportCharacter:Destroy()
        end
        
        character.Archivable = true
        self.ViewportCharacter = character:Clone()
        self.ViewportCharacter.Parent = self.CharacterPort
        self.ViewportCharacter.Name = "Character"
        
        -- Default Position
        self.ViewportCharacter:SetPrimaryPartCFrame(CFrame.new(Vector3.zero) * CFrame.Angles(0, math.rad(180), 0))
    end

    if LocalPlayer.Character then
        LoadCharacter(LocalPlayer.Character)
    end
    LocalPlayer.CharacterAdded:Connect(LoadCharacter)

    -- Handle Rotation safely
    RunService.RenderStepped:Connect(function()
        if not self.UIEnabled or not self.ViewportCharacter then return end
        
        local rootPart = self.ViewportCharacter:FindFirstChild("HumanoidRootPart")
        if rootPart then
            local distance = 8.25
            local camOffset = CFrame.new(0, 0, distance)
            local rotatedOffset = CFrame.new(rootPart.Position) * CFrame.Angles(0, math.rad(self.RotationY), 0) * camOffset
            self.ViewportCamera.CFrame = CFrame.new(rotatedOffset.Position, rootPart.Position)
        end
    end)
end

-- // Method: Setup Animations
function InventoryHandler:SetupAnimations()
    self.InventoryBlur = Instance.new("BlurEffect", Lighting)
    self.InventoryBlur.Size = 0

    -- Tween Caching for performance
    self.Tweens = {
        BlurIn = TweenService:Create(self.InventoryBlur, TweenInfo.new(1), {Size = 24}),
        BlurOut = TweenService:Create(self.InventoryBlur, TweenInfo.new(0.5), {Size = 0}),
        ZoomIn = TweenService:Create(self.ViewportCamera, TweenInfo.new(0.75), {FieldOfView = 70}),
        ZoomOut = TweenService:Create(self.ViewportCamera, TweenInfo.new(0.75), {FieldOfView = 90}),
        LPZoomIn = TweenService:Create(LPCamera, TweenInfo.new(0.75), {FieldOfView = 60}),
        LPZoomOut = TweenService:Create(LPCamera, TweenInfo.new(0.75), {FieldOfView = 70}),
        BgShow = TweenService:Create(self.UIBackground, TweenInfo.new(0.5), {BackgroundTransparency = 0.4}),
        BgHide = TweenService:Create(self.UIBackground, TweenInfo.new(0.5), {BackgroundTransparency = 1}),
        PortShow = TweenService:Create(self.CharacterPortBG, TweenInfo.new(0.5), {Position = UDim2.new(0.229, 0, 0.493, 0), Size = UDim2.new(0.182, 0, 0.563, 0)}),
        PortHide = TweenService:Create(self.CharacterPortBG, TweenInfo.new(0.5), {Position = UDim2.new(0.229, 0, 0.493, 0), Size = UDim2.new(0, 0, 0, 0)}),
        SlotsShow = TweenService:Create(self.ItemSlotsMain, TweenInfo.new(0.33), {Size = UDim2.new(0.432, 0, 0.128, 0)}),
        SlotsHide = TweenService:Create(self.ItemSlotsMain, TweenInfo.new(0.33), {Size = UDim2.new(0, 0, 0, 0)})
    }
    
    -- Setup Hotbar layout defaults
    TweenService:Create(self.HotbarGrid, TweenInfo.new(0.5), {CellSize = UDim2.new(0.172, 0, 0.76, 0)}):Play()
    TweenService:Create(self.HotbarGrid, TweenInfo.new(0.75), {CellPadding = UDim2.new(0.02, 0, 0.027, 0)}):Play()
end

-- // Method: UI Toggle Logic
function InventoryHandler:ToggleUI(state)
    self.UIEnabled = state
    self.ItemSlotsMain.Visible = state
    self.ClothMain.Visible = state
    self.UI.FreeMouse.Visible = state

    if state then
        self.Tweens.ZoomIn:Play()
        self.Tweens.LPZoomIn:Play()
        self.Tweens.BlurIn:Play()
        self.Tweens.BgShow:Play()
        self.Tweens.PortShow:Play()
        self.Tweens.SlotsShow:Play()
        SoundService.Inventory:Play()

        for Slot, OriginalPos in pairs(self.ClothSlotsPositionTB) do
            TweenService:Create(Slot, TweenInfo.new(0.33), {Position = OriginalPos.Position, Size = OriginalPos.Size}):Play()
        end
    else
        self.Tweens.ZoomOut:Play()
        self.Tweens.LPZoomOut:Play()
        self.Tweens.BlurOut:Play()
        self.Tweens.BgHide:Play()
        self.Tweens.PortHide:Play()
        self.Tweens.SlotsHide:Play()

        for Slot, OriginalPos in pairs(self.ClothSlotsPositionTB) do
            TweenService:Create(Slot, TweenInfo.new(0.33), {Size = UDim2.new(0.01, 0, 0.01, 0)}):Play()
        end
    end
end

-- // Method: Parse Inventory Slots
function InventoryHandler:SetupSlots()
    local BL = {"Hotbar", "Main"}

    local function RegisterSlot(Slot)
        if Slot:IsA("Frame") and not table.find(BL, Slot.Name) then
            local slotnumber = tonumber(Slot.Name)
            if slotnumber then
                self.Inventory[slotnumber] = self.Inventory[slotnumber] or {}
            end
        end
    end

    for _, Slot in pairs(self.ItemSlots:GetDescendants()) do
        RegisterSlot(Slot)
    end

    self.ItemSlots.DescendantAdded:Connect(RegisterSlot)
end

-- // Method: Network Signals
function InventoryHandler:SetupNetwork()
    AddItem.OnClientEvent:Connect(function(Name, Amount)
        Utility:AddItem(self.Inventory, Name, Amount)
    end)

    RemoveItem.OnClientEvent:Connect(function(Name, Amount)
        Utility:RemoveItem(self.Inventory, Name, Amount)
    end)
end

-- // Method: Input Handling (Dragging & Toggling)
function InventoryHandler:SetupInput()
    -- UI Toggle
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == self.KeyBind then
            if tick() - self.LastPressed < self.Cooldown then return end
            self.LastPressed = tick()
            self:ToggleUI(not self.UIEnabled)
        end
    end)

    -- Viewport Rotation & Item Dragging Initialization
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if not self.UIEnabled or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

        local mousePos = UserInputService:GetMouseLocation()
        
        -- Check Viewport Drag
        local absPos = self.CharacterPort.AbsolutePosition
        local absSize = self.CharacterPort.AbsoluteSize
        if mousePos.X >= absPos.X and mousePos.X <= absPos.X + absSize.X and mousePos.Y >= absPos.Y and mousePos.Y <= absPos.Y + absSize.Y then
            self.DraggingViewport = true
            self.LastMousePosition = mousePos
            return
        end

        -- Check Item Grab
        self.SelectedUI = Utility:GetGrabbingUI()
        self.MainSelected = self.SelectedUI

        if self.SelectedUI then
            if self.MainSelected.UIStroke.Color ~= Color3.fromRGB(0, 175, 0) then
                TweenService:Create(self.MainSelected.UIStroke, TweenInfo.new(0.1), {Color = Color3.fromRGB(255, 255, 255)}):Play()
            end

            local CanvasFrame = self.SelectedUI.CanvasGroup.Frame
            TweenService:Create(CanvasFrame, TweenInfo.new(0.125), {Transparency = 0, Position = UDim2.new(0, 0, 0, 0), Rotation = 180}):Play()

            self.SelectedUI = self.SelectedUI:Clone()
            self.SelectedUI.Size = UDim2.new(0.075, 0, 0.109, 0)
            self.SelectedUI.Parent = self.UI
            self.SelectedUI.Position = UDim2.fromOffset(mousePos.X, mousePos.Y)

            self.SelectedUI.UIStroke.Transparency = 1
            self.SelectedUI.BarFrame.Visible = false
            self.SelectedUI.BackgroundTransparency = 1
            self.SelectedUI.SlotImage.ImageTransparency = 0.5
            self.SelectedUI.CanvasGroup.Visible = false

            -- Efficient Dragging Update (NO TWEENS)
            self.GrabUpdate = RunService.RenderStepped:Connect(function()
                local currentMouse = UserInputService:GetMouseLocation()
                -- Direct CFrame/Position update is infinitely faster than TweenService here
                self.SelectedUI.Position = UDim2.fromOffset(currentMouse.X, currentMouse.Y)
            end)
        end
    end)

    -- Handle Drag Movement (Viewport)
    UserInputService.InputChanged:Connect(function(input, gameProcessed)
        if self.DraggingViewport and input.UserInputType == Enum.UserInputType.MouseMovement then
            local currentPosition = UserInputService:GetMouseLocation()
            local delta = currentPosition - self.LastMousePosition
            self.LastMousePosition = currentPosition
            self.RotationY = self.RotationY - delta.X * 0.5
        end
    end)

    -- Item Drop & Viewport Drag End
    UserInputService.InputEnded:Connect(function(input, gameProcessed)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self.DraggingViewport = false
            
            if self.SelectedUI and self.GrabUpdate then
                self.SelectedUI:Destroy()
                self.GrabUpdate:Disconnect()
                self.GrabUpdate = nil

                local CanvasFrame = self.MainSelected.CanvasGroup.Frame
                TweenService:Create(CanvasFrame, TweenInfo.new(0.125), {Transparency = 0.9, Position = UDim2.new(0.681, 0, -0.662, 0), Rotation = 45}):Play()

                local SlotToSwitch = Utility:GetGrabbingUI()
                if SlotToSwitch and SlotToSwitch ~= self.MainSelected then
                    Utility:SwitchSlots(self.Inventory, tonumber(self.MainSelected.Name), tonumber(SlotToSwitch.Name))
                    SoundService.Select:Play()
                elseif self.MainSelected.UIStroke.Color == Color3.fromRGB(0, 175, 0) then
                    TweenService:Create(self.MainSelected.UIStroke, TweenInfo.new(0.1), {Color = Color3.fromRGB(62, 62, 62)}):Play()
                end
                
                self.SelectedUI = nil
                self.MainSelected = nil
            end
        end
    end)
end

-- // Initialize and Return
InventoryHandler:Initialize()
return InventoryHandler
