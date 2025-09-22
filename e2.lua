local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService")

-- Local Player and Character References
local LOCAL_PLAYER = Players.LocalPlayer
local CHARACTER = LOCAL_PLAYER.Character or LOCAL_PLAYER.CharacterAdded:Wait()
local HUMAN_ROOT_PART = CHARACTER:WaitForChild("HumanoidRootPart")
local HUMAN_OID = CHARACTER:FindFirstChildOfClass("Humanoid")

-- Game Specific Folders (using WaitForChild for robustness)
local WORKSPACE_FOLDER = Workspace:WaitForChild("game", 10) -- Added timeout for robustness
local SHARED_FOLDER = ReplicatedStorage:WaitForChild("network", 10):WaitForChild("Shared", 10)
local REMOTES_FOLDER = ReplicatedStorage.network.Shared -- Assuming this path is stable after SHARED_FOLDER

-- Constants for folder names and object names
local TARGET_FOLDER_NAME = "Found"
local PARENT_FOLDER_NAME = "Here"
local HI_OBJECT_NAME = "hi" -- Used for blocking name changes and remote events

-- Ball tracking for reach feature
local CACHED_BALL = nil
local LAST_BALL_CHECK_TIME = 0
local BALL_CHECK_INTERVAL = 0.1
local TARGET_COLOR = BrickColor.new(Color3.fromRGB(237, 234, 234))

-- Auto Goal / Freekick Logic
local AIMING_ENABLED = false
local USE_FREEKICK_LOGIC = false
local PATH_ENABLED = false
local AUTO_GOAL_PROJECTILES = {} -- Stores balls currently being auto-shot
local PATH_MARKERS = {} -- Visual markers for the ball's trajectory
local PATH_COLOR = Color3.fromRGB(96, 205, 255)
local PATH_TRANSPARENCY = 0
local TOUCHED_BALLS = {} -- Tracks balls touched for freekick logic

-- Ball physics for Power Shot and Ball Freeze
local MAX_VELOCITY = 500
local Y_AXIS_MULTIPLIER = 1
local TRACKED_BALL = nil -- The ball currently being targeted by Ball Freeze/Bring Ball
local BALL_STATE = {
    OriginalProperties = nil, -- Stores original velocity for unfreezing
    IsPaused = false
}

-- UI Connections and Managers
local TOGGLE_CONNECTIONS = {} -- Stores connections that need to be disconnected when a toggle is off
local REACH_CONNECTIONS = {} -- Specific connections for the Reach feature (though now consolidated)

local CELEBRATIONS = {
    ["None"] = "",
    ["Fist Pump"] = "rbxassetid://18545628047",
    ["Right Here Right Now"] = "rbxassetid://18548417924",
    ["Tshabalala"] = "rbxassetid://18673725349",
    ["Archer Slide"] = "rbxassetid://18560742891",
    ["Point Up"] = "rbxassetid://18563918200",
    ["The Griddy"] = "rbxassetid://18774591442",
    ["Boxing"] = "rbxassetid://18584841032",
    ["Glorious"] = "rbxassetid://18584847345",
    ["Yoga"] = "rbxassetid://18673721840",
    ["Calma"] = "rbxassetid://18673636723",
    ["Shivering"] = "rbxassetid://18673647071",
    ["Folded Arms Knee Slide"] = "rbxassetid://18673668417",
    ["Gunleann"] = "rbxassetid://18673677815",
    ["Knockout"] = "rbxassetid://18673687513",
    ["Salute Knee Slide"] = "rbxassetid://18673699107",
    ["Meditation"] = "rbxassetid://18673705797",
    ["Ice Cold"] = "rbxassetid://18745497583",
    ["Catwalk"] = "rbxassetid://18775156520",
    ["Backflip"] = "rbxassetid://18926012773",
    ["Double Siuuu"] = "rbxassetid://18926038745",
    ["Prayerr"] = "rbxassetid://18926177589",
    ["Folded Arms"] = "rbxassetid://18926195587",
    ["Spanish Dance"] = "rbxassetid://18926223307",
    ["Pigeon"] = "rbxassetid://109637224628241",
    ["Strange Dance"] = ""
}
local REFEREE_ANIMS = {
    ["None"] = "",
    ["Card"] = "rbxassetid://16096886456",
    ["Penalty"] = "rbxassetid://16096985868",
    ["Warning"] = "rbxassetid://16096947622",
    ["Advantage"] = "rbxassetid://16097904170",
    ["Whistle"] = "rbxassetid://16096892797"
}
local STADIUM_NAMES = {
    "Default", "Central Coast Stadium", "Community Arena", "Custom Team", "Eastwood Park",
    "Exmouth Memorial Park", "Follow Your Dreams Arena", "Futbol Arena", "Gorgie Park",
    "Horizon Stadium", "Lochview Stadium", "Sanctuary Lane", "Skyline Field", "Square Arena",
    "Stade de Futbol", "The Range", "Training Ground", "Westbridge Road"
}

-- Kick module references for enhanced charge
local KICK_MODULES = {}
local ORIGINAL_CHARGE_SPEEDS = {}

-- Predefined corner positions for auto-goal
local CORNER_POSITIONS = {
    ["Away Top Left"] = CFrame.new(13, 7.9000001, 359.299988, 1, 0, 0, 0, 1, 0, 0, 0, 1),
    ["Away Top Right"] = CFrame.new(-13.8999996, 7.9000001, 359.299988, 1, 0, 0, 0, 1, 0, 0, 0, 1),
    ["Home Top Left"] = CFrame.new(-13.8999996, 9.60000038, -354.700012, 1, 0, 0, 0, 1, 0, 0, 0, 1),
    ["Home Top Right"] = CFrame.new(13.8000002, 9.60000038, -354.700012, 1, 0, 0, 0, 1, 0, 0, 0, 1)
}
local SELECTED_TARGET_CFRAME = CORNER_POSITIONS["Away Top Left"]

local function playAnimation(animId, animName)
    if not animId or animId == "" then
        return
    end
    local character = LOCAL_PLAYER.Character or LOCAL_PLAYER.CharacterAdded:Wait()
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return
    end

    local animator = humanoid:FindFirstChild("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    local animation = Instance.new("Animation")
    animation.AnimationId = animId
    animation.Name = animName
    
    local success, result = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    if success and result then
        result:Play()
    end
end

-- Finds a remote event or function within the Shared folder or its descendants
local function findRemote(name)
    local remote = SHARED_FOLDER:FindFirstChild(name)
    if remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction")) then
        return remote
    end
    -- Fallback to searching all descendants of ReplicatedStorage if not found directly in Shared
    -- This can be inefficient if 'name' is not unique or path is unknown
    for _, obj in pairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") and obj.Name == name then
            return obj
        end
    end
    return nil
end

-- Gets a list of names of all other players in the game
local function getPlayerNames()
    local playerNames = {}
    for _, plr in pairs(Players:GetPlayers()) do
        if plr ~= LOCAL_PLAYER then
            table.insert(playerNames, plr.Name)
        end
    end
    return playerNames
end

-- Sends remote call to ragdoll a player's character
local function ragdollPlayer(plr)
    if plr and plr.Character then
        local networkRemote = findRemote(HI_OBJECT_NAME)
        if networkRemote then
            networkRemote:FireServer(1000, "ballAttribute", plr.Character, "serverRagdollBinder", true)
            networkRemote:FireServer(1000, "ballAttribute", plr.Character, "clientRagdollBinder", true)
        end
    end
end

-- Sends remote call to unragdoll a player's character
local function unragdollPlayer(plr)
    if plr and plr.Character then
        local networkRemote = findRemote(HI_OBJECT_NAME)
        if networkRemote then
            networkRemote:FireServer(1000, "ballAttribute", plr.Character, "serverRagdollBinder", false)
            networkRemote:FireServer(1000, "ballAttribute", plr.Character, "clientRagdollBinder", false)
        end
    end
end

-- Updates the player dropdowns in the UI
local function updatePlayerDropdowns()
    local newValues = getPlayerNames()
    local ragdollDropdown = Tabs.OP:FindFirstChild("RagdollPlayerDropdown")
    local unragdollDropdown = Tabs.OP:FindFirstChild("UnragdollPlayerDropdown")
    if ragdollDropdown then
        ragdollDropdown:SetValues(newValues)
    end
    if unragdollDropdown then
        unragdollDropdown:SetValues(newValues)
    end
end

-- Updates the charge speeds of kick modules
local function updateChargeSpeeds(multiplier)
    for name, mod in pairs(KICK_MODULES) do
        if mod and typeof(mod.chargeSpeed) == "number" then
            mod.chargeSpeed = ORIGINAL_CHARGE_SPEEDS[name] * multiplier
        end
    end
end

-- Clears all visual path markers
local function clearPathMarkers()
    for _, marker in pairs(PATH_MARKERS) do
        marker:Destroy()
    end
    PATH_MARKERS = {}
end

-- Creates visual path markers along a bezier curve
local function createPathMarkers(startPos, targetPos, controlPoint, duration)
    clearPathMarkers()
    local numMarkers = 20
    local step = 1 / numMarkers
    for t = 0, 1, step do
        local pos = (1 - t)^2 * startPos + 2 * (1 - t) * t * controlPoint + t^2 * targetPos
        local marker = Instance.new("Part")
        marker.Size = Vector3.new(0.5, 0.5, 0.5)
        marker.Position = pos
        marker.Anchored = true
        marker.CanCollide = false
        marker.Color = PATH_COLOR
        marker.Transparency = PATH_TRANSPARENCY
        marker.Material = Enum.Material.Neon
        marker.Parent = Workspace
        table.insert(PATH_MARKERS, marker)
    end
end

-- Shoots a ball towards a target using a parabolic trajectory
local function shootBall(ball)
    local startPos = ball.Position
    local targetPos = SELECTED_TARGET_CFRAME.Position

    if not targetPos or not (targetPos.X and targetPos.Y and targetPos.Z) then
        targetPos = CORNER_POSITIONS["Away Top Left"].Position
    end

    local distance = (targetPos - startPos).Magnitude
    local midPoint = (startPos + targetPos) / 2
    
    -- Dynamically get values from UI sliders
    local maxHeight = Options.MaxHeightSlider.Value
    local xArchWidth = Options.XArchSlider.Value
    local moveSpeed = Options.PowerSlider.Value

    local yOffset = math.max(maxHeight, distance * 0.1)
    yOffset = math.clamp(yOffset, 2, 50)
    local controlY = math.max(startPos.Y, targetPos.Y) + yOffset
    local xDirection = math.sign(targetPos.X - startPos.X)
    local xDistance = math.abs(targetPos.X - startPos.X)
    local xOffset = xDistance * xArchWidth * 0.5 * 3
    local controlX = midPoint.X + (xOffset * xDirection)
    local controlPoint = Vector3.new(controlX, controlY, midPoint.Z)

    local bav = Instance.new("BodyAngularVelocity", ball)
    bav.MaxTorque = Vector3.new(100000, 100000, 100000)
    bav.P = 10000
    bav.AngularVelocity = Vector3.new(math.random(-1, 1), math.random(-1, 1), math.random(-1, 1)) * 1500

    if PATH_ENABLED then
        createPathMarkers(startPos, targetPos, controlPoint, distance / moveSpeed)
    end

    local t = 0
    local duration = distance / moveSpeed
    local step = 1 / (duration * 60)
    local gravity = Vector3.new(0, -32, 0)

    local connection
    connection = RunService.Heartbeat:Connect(function()
        t = t + step
        if t >= 1 then
            t = 1
            connection:Disconnect()
            if ball:FindFirstChildOfClass("BodyAngularVelocity") then
                ball.BodyAngularVelocity:Destroy()
            end
            clearPathMarkers()
            ball.Velocity = Vector3.new(0, 0, 0)
            ball.RotVelocity = Vector3.new(0, 0, 0)
            -- Remove ball from active projectiles list
            for i, v in pairs(AUTO_GOAL_PROJECTILES) do
                if v == ball then
                    table.remove(AUTO_GOAL_PROJECTILES, i)
                    break
                end
            end
        end

        local newPos = (1 - t)^2 * startPos + 2 * (1 - t) * t * controlPoint + t^2 * targetPos
        local velocity = (newPos - ball.Position) * 60
        if t > 0.95 then -- Apply slowdown near the end of trajectory
            local slowdownFactor = 1 - (t - 0.95) * 10
            velocity = velocity * slowdownFactor + gravity * (1 - slowdownFactor)
        end
        ball.Velocity = velocity
    end)

    table.insert(AUTO_GOAL_PROJECTILES, ball)
end

-- Sets up touch detection for character's boots/feet to trigger freekick logic
local function setupBootTouchDetection()
    local leftBoot = CHARACTER:FindFirstChild("LeftBoot") or CHARACTER:WaitForChild("LeftBoot", 5)
    local rightBoot = CHARACTER:FindFirstChild("RightBoot") or CHARACTER:WaitForChild("RightBoot", 5)
    
    if leftBoot then
        leftBoot.Touched:Connect(function(hit)
            if hit:FindFirstChild("network") then
                TOUCHED_BALLS[hit] = true
            end
        end)
    end
    
    if rightBoot then
        rightBoot.Touched:Connect(function(hit)
            if hit:FindFirstChild("network") then
                TOUCHED_BALLS[hit] = true
            end
        end)
    end
end

-- Initialization functions
-- Scans for parts with "friction" and renames their parent folders
local function scanForFriction(folder)
    for _, part in pairs(folder:GetDescendants()) do
        if part:IsA("BasePart") then
            local friction = part:FindFirstChild("friction")
            if friction then
                local parentFolder = part.Parent
                if parentFolder and parentFolder.Name ~= TARGET_FOLDER_NAME then
                    parentFolder.Name = TARGET_FOLDER_NAME
                    parentFolder.Changed:Connect(function()
                        if parentFolder.Name ~= TARGET_FOLDER_NAME then
                            parentFolder.Name = TARGET_FOLDER_NAME
                        end
                        if parentFolder.Parent and parentFolder.Parent.Name ~= PARENT_FOLDER_NAME then
                            parentFolder.Parent.Name = PARENT_FOLDER_NAME
                        end
                    end)
                end
            end
        end
    end
end

-- Enforces specific naming and properties for objects in the Shared folder
local function setupNameChangeBlockers()
    local function enforceName(child)
        if child:IsA("BasePart") or child:IsA("Model") then
            child.Anchored = true
            child.Locked = true
        end
        child:GetPropertyChangedSignal("Name"):Connect(function()
            if child.Name ~= HI_OBJECT_NAME then
                child.Name = HI_OBJECT_NAME
            end
        end)
    end

    -- Apply to existing children
    for _, child in pairs(SHARED_FOLDER:GetChildren()) do
        child.Name = HI_OBJECT_NAME
        enforceName(child)
    end

    -- Apply to newly added children
    SHARED_FOLDER.ChildAdded:Connect(function(child)
        child.Name = HI_OBJECT_NAME
        enforceName(child)
    end)
end

-- Initializes kick modules for enhanced charge feature
local function setupKickModules()
    local kickBindsFolder = LOCAL_PLAYER.PlayerScripts:FindFirstChild("mechanics") and LOCAL_PLAYER.PlayerScripts.mechanics:FindFirstChild("kick") and LOCAL_PLAYER.PlayerScripts.mechanics.kick:FindFirstChild("binds")
    if kickBindsFolder then
        for _, module in pairs(kickBindsFolder:GetChildren()) do
            if module:IsA("ModuleScript") then
                local success, requiredModule = pcall(require, module)
                if success and requiredModule and typeof(requiredModule.chargeSpeed) == "number" then
                    KICK_MODULES[module.Name] = requiredModule
                    ORIGINAL_CHARGE_SPEEDS[module.Name] = requiredModule.chargeSpeed
                end
            end
        end
    end
end

-- Creates a highlight for the ball
local function setupBallHighlight()
    local ball = WORKSPACE_FOLDER:FindFirstChild("ball")
    if ball and ball:IsA("BasePart") then
        local highlight = Instance.new("Highlight")
        highlight.Parent = ball
        return highlight
    end
    return nil
end

-- Stores highlight instances for team members and opponents
local TEAM_HIGHLIGHTS = {}
local OPPOSING_HIGHLIGHTS = {}

-- Creates a highlight for a given player's character
local function createPlayerHighlight(plr)
    if plr.Character then
        local highlight = Instance.new("Highlight")
        if plr.Team == LOCAL_PLAYER.Team then
            highlight.FillColor = Color3.fromRGB(0, 255, 0) -- Green for teammates
            highlight.OutlineColor = Color3.fromRGB(0, 255, 0)
            highlight.Parent = plr.Character
            table.insert(TEAM_HIGHLIGHTS, highlight)
        elseif plr.Team and plr.Team ~= LOCAL_PLAYER.Team then
            highlight.FillColor = Color3.fromRGB(255, 0, 0) -- Red for opponents
            highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
            highlight.Parent = plr.Character
            table.insert(OPPOSING_HIGHLIGHTS, highlight)
        end
    end
end

-- Sets up highlights for all players, updating on player join/leave and character changes
local function setupTeamHighlights()
    -- Clear existing highlights before setting up new ones
    clearTeamHighlights() 
    for _, plr in pairs(Players:GetPlayers()) do
        createPlayerHighlight(plr)
    end
    -- Connect to PlayerAdded for new players
    TOGGLE_CONNECTIONS.PlayerAddedHighlight = Players.PlayerAdded:Connect(function(plr)
        if Options.TeamHighlightToggle.Value then
            createPlayerHighlight(plr)
        end
    end)
    -- Connect to CharacterAdded for existing players whose characters respawn
    TOGGLE_CONNECTIONS.CharacterAddedHighlight = Players.CharacterAdded:Connect(function(char)
        if Options.TeamHighlightToggle.Value then
            local plr = Players:GetPlayerFromCharacter(char)
            if plr then
                createPlayerHighlight(plr)
            end
        end
    end)
end

-- Removes all active team and opposing highlights
local function clearTeamHighlights()
    if TOGGLE_CONNECTIONS.PlayerAddedHighlight then
        TOGGLE_CONNECTIONS.PlayerAddedHighlight:Disconnect()
        TOGGLE_CONNECTIONS.PlayerAddedHighlight = nil
    end
    if TOGGLE_CONNECTIONS.CharacterAddedHighlight then
        TOGGLE_CONNECTIONS.CharacterAddedHighlight:Disconnect()
        TOGGLE_CONNECTIONS.CharacterAddedHighlight = nil
    end

    for _, highlight in pairs(TEAM_HIGHLIGHTS) do
        highlight:Destroy()
    end
    for _, highlight in pairs(OPPOSING_HIGHLIGHTS) do
        highlight:Destroy()
    end
    TEAM_HIGHLIGHTS = {}
    OPPOSING_HIGHLIGHTS = {}
end

RunService.Heartbeat:Connect(function()
    if AIMING_ENABLED and USE_FREEKICK_LOGIC then
        for _, v in pairs(Workspace:GetDescendants()) do
            if v:IsA("BasePart") and v:FindFirstChild("network") and TOUCHED_BALLS[v] then
                shootBall(v)
                TOUCHED_BALLS[v] = nil
            end
        end
    end

    if Options.RagdollAuraToggle.Value and LOCAL_PLAYER.Character and LOCAL_PLAYER.Character:FindFirstChild("HumanoidRootPart") then
        local radius = Options.AuraRadiusSlider.Value
        local localPos = LOCAL_PLAYER.Character.HumanoidRootPart.Position

        for _, plr in pairs(Players:GetPlayers()) do
            if plr ~= LOCAL_PLAYER and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
                if (plr.Character.HumanoidRootPart.Position - localPos).Magnitude <= radius then
                    ragdollPlayer(plr)
                end
            end
        end
    end
end)

local library = loadstring(game:GetObjects("rbxassetid://7657867786")[1].Source)()

-- Create the main window for Pepsi's UI
local Window = library:CreateWindow({
    Name = "Omnix Hub | RF24/RFL",
    Themeable = {
        Info = "by Omnix Hub"
    }
})

-- Create the main tab for Pepsi's UI
local MainTab = Window:CreateTab({
    Name = "Main"
})

-- Create a section within the tab for the controls
local MainSection = MainTab:CreateSection({
    Name = "Main"
})

local MiscTab = Window:CreateTab({
    Name = "Misc"
})

local MiscSection = MiscTab:CreateSection({
    Name = "Misc"
})

local PlayerTab = Window:CreateTab({
    Name = "Player"
})

local PlayerSection = PlayerTab:CreateSection({
    Name = "Player"
})

local AdminTab = Window:CreateTab({
    Name = "Admin"
})

local AdminSection = AdminTab:CreateSection({
    Name = "Admin"
})

local AutoTab = Window:CreateTab({
    Name = "Auto Features"
})

local AutoSection = AutoTab:CreateSection({
    Name = "Auto Features"
})

-- The core game logic from the original script starts here
for _, v in pairs(getgc(true)) do
    if type(v) == "table" and rawget(v, "gkCheck") then
        local constants = debug.getconstants(v.react)
        for i, val in pairs(constants) do
            if val == "ignoreReactDecline" or val == "specialTool" then
                debug.setconstant(v.react, i, "ball")
            elseif val == "overlapCheck" then
                rawset(v, "check", function() return true end)
                debug.setconstant(v.react, i, "check")
            end
        end
    end
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")

player.CharacterAdded:Connect(function(newChar)
    character = newChar
    humanoid = character:WaitForChild("Humanoid")
    humanoidRootPart = character:WaitForChild("HumanoidRootPart")
end)

-- Initial size variables for the hitbox
local REACH_X, REACH_Y, REACH_Z = 6, 6, 6
local REACH_ENABLED = false
local staminaConnection
local predictorEnabled = false
local predictionLine
local kickAnimationPlaying = false

local HitboxPart = Instance.new("Part")
HitboxPart.Name = "Hitbox"
HitboxPart.Anchored = true
HitboxPart.CanCollide = false
HitboxPart.Transparency = 1
-- Set the initial size using the new variables
HitboxPart.Size = Vector3.new(REACH_X, REACH_Y, REACH_Z)
HitboxPart.Material = Enum.Material.SmoothPlastic
HitboxPart.Parent = workspace

local HitboxSelection = Instance.new("SelectionBox", HitboxPart)
HitboxSelection.Name = "Selection"
HitboxSelection.Adornee = HitboxPart
HitboxSelection.LineThickness = 0.02
HitboxSelection.Color3 = Color3.fromRGB(255, 0, 0)
HitboxSelection.Transparency = 1

local targetAnimationIds = {}
local function scanToolAnimations()
    local toolsFolder = ReplicatedStorage:FindFirstChild("game")
        and ReplicatedStorage.game:FindFirstChild("animations")
        and ReplicatedStorage.game.animations:FindFirstChild("Tools")
    if not toolsFolder then return end
    for _, anim in ipairs(toolsFolder:GetDescendants()) do
        if anim:IsA("Animation") then
            targetAnimationIds[anim.AnimationId] = true
        end
    end
end
scanToolAnimations()

humanoid.AnimationPlayed:Connect(function(animationTrack)
    if targetAnimationIds[animationTrack.Animation.AnimationId] then
        kickAnimationPlaying = true
        animationTrack.Stopped:Connect(function()
            kickAnimationPlaying = false
        end)
    end
end)

local function getBall()
    local balls = CollectionService:GetTagged("Ball")
    local ball = balls[1]
    if ball then
        ball.CanTouch = true
        ball.CastShadow = false

        -- look for the "network" folder inside the ball
        local networkFolder = ball:FindFirstChild("network")
        if networkFolder then
            local netOwner = networkFolder:FindFirstChild("networkOwner")
            local owner = networkFolder:FindFirstChild("owner")

            -- force ownership spoof
            if netOwner and netOwner:IsA("ObjectValue") then
                netOwner.Value = Players.LocalPlayer
            end
            if owner and owner:IsA("ObjectValue") then
                owner.Value = Players.LocalPlayer
            end
        end
    end
    return ball
end

local function updatePrediction()
    if not predictorEnabled then
        if predictionLine then
            predictionLine:Destroy()
            predictionLine = nil
        end
        return
    end

    local ball = getBall()
    if not ball then return end

    local velocity = ball.AssemblyLinearVelocity
    if velocity.Magnitude < 1 then
        if predictionLine then
            predictionLine:Destroy()
            predictionLine = nil
        end
        return
    end

    local predictedPos = ball.Position + (velocity * 0.5)
    if not predictionLine then
        predictionLine = Instance.new("Part")
        predictionLine.Anchored = true
        predictionLine.CanCollide = false
        predictionLine.CanTouch = false
        predictionLine.CastShadow = false -- 🔑 no shadows
        predictionLine.Material = Enum.Material.Neon
        predictionLine.Color = Color3.fromRGB(0, 255, 0)
        predictionLine.Parent = workspace
    end

    local midpoint = (ball.Position + predictedPos) / 2
    predictionLine.Size = Vector3.new(0.2, 0.2, (ball.Position - predictedPos).Magnitude)
    predictionLine.CFrame = CFrame.new(midpoint, predictedPos)
end

local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Blacklist
params.FilterDescendantsInstances = {HitboxPart}

RunService.Heartbeat:Connect(function()
    if predictorEnabled then
        updatePrediction()
    end

    if character and humanoidRootPart and REACH_ENABLED then
        -- keep hitbox updated
        HitboxPart.CFrame = humanoidRootPart.CFrame
        HitboxPart.Size = Vector3.new(REACH_X, REACH_Y, REACH_Z)
        HitboxPart.CanTouch = true
        HitboxPart.CastShadow = false

        local ball = getBall()
        if ball and kickAnimationPlaying then
            local maxReach = math.max(REACH_X, REACH_Y, REACH_Z)
            local distance = (ball.Position - humanoidRootPart.Position).Magnitude
            if distance <= maxReach then
                for _, limbName in ipairs({"LeftFoot","RightFoot","Left Leg","Right Leg"}) do
                    local limb = character:FindFirstChild(limbName)
                    if limb then
                        limb.CanTouch = true
                        limb.CastShadow = false
                        pcall(function()
                            firetouchinterest(limb, ball, 0)
                            firetouchinterest(limb, ball, 1)
                        end)
                    end
                end
            end
        end

        -- optional: still interact with other networked parts
        for _, part in ipairs(workspace:GetPartsInPart(HitboxPart, params)) do
            if part:IsA("BasePart") and part.Parent ~= character and part ~= ball then
                if part:GetAttribute("networkOwner") or part:GetAttribute("lastTouch") or
                   (part.Parent and part.Parent.Name == "game") then
                    for _, limbName in ipairs({"LeftFoot","RightFoot","Left Leg","Right Leg"}) do
                        local limb = character:FindFirstChild(limbName)
                        if limb and kickAnimationPlaying then
                            limb.CanTouch = true
                            limb.CastShadow = false
                            pcall(function()
                                firetouchinterest(limb, part, 0)
                                firetouchinterest(limb, part, 1)
                            end)
                        end
                    end
                end
            end
        end
    end
end)

-- UI creation using Pepsi's library, controlling the above logic
MainSection:AddToggle({
    Name = "Enable Reach",
    Flag = "MainSection_LegReach",
    Callback = function(Value)
        REACH_ENABLED = Value
        if Value then
            HitboxSelection.Transparency = 0.8
            HitboxPart.Transparency = 0.7
        else
            HitboxSelection.Transparency = 1
            HitboxPart.Transparency = 1
        end
    end
})

-- Replaced the textbox with three sliders for X, Y, and Z
MainSection:AddSlider({
    Name = "Reach X",
    Flag = "MainSection_ReachX",
    Value = REACH_X,
    Precise = 1,
    Min = 1,
    Max = 1000,
    Callback = function(Value)
        REACH_X = Value
    end
})

MainSection:AddSlider({
    Name = "Reach Y",
    Flag = "MainSection_ReachY",
    Value = REACH_Y,
    Precise = 1,
    Min = 1,
    Max = 1000,
    Callback = function(Value)
        REACH_Y = Value
    end
})

MainSection:AddSlider({
    Name = "Reach Z",
    Flag = "MainSection_ReachZ",
    Value = REACH_Z,
    Precise = 1,
    Min = 1,
    Max = 1000,
    Callback = function(Value)
        REACH_Z = Value
    end
})

MainSection:AddToggle({
    Name = "Show Hitbox Visualizer",
    Flag = "MainSection_ShowHitbox",
    Callback = function(Value)
        if REACH_ENABLED and Value then
            HitboxSelection.Transparency = 0.8
        else
            HitboxSelection.Transparency = 1
        end
    end
})

MiscSection:AddToggle({
    Name = "Infinite Stamina",
    Flag = "MainSection_InfiniteStamina",
    Callback = function(Value)
        local ps = player:WaitForChild("PlayerScripts")
        local controllers = ps:WaitForChild("controllers")
        local movement = controllers:WaitForChild("movementController")
        local stamina = movement:WaitForChild("stamina")

        if Value then
            stamina.Value = 100
            staminaConnection = stamina:GetPropertyChangedSignal("Value"):Connect(function()
                stamina.Value = 100
            end)
        else
            if staminaConnection then
                staminaConnection:Disconnect()
                staminaConnection = nil
            end
        end
    end
})

MainSection:AddButton({
    Name = "Bring Ball (If Owner)",
    Callback = function()
        local ball = getBall()
        if ball then
            local networkFolder = ball:FindFirstChild("network")
            if networkFolder then
                local netOwner = networkFolder:FindFirstChild("networkOwner")
                if netOwner and netOwner.Value == Players.LocalPlayer then
                    -- ✅ we are the owner, bring the ball
                    local hrp = humanoidRootPart
                    if hrp then
                        ball.CFrame = hrp.CFrame * CFrame.new(0, -2, -1) -- place near feet
                        ball.AssemblyLinearVelocity = Vector3.zero
                        ball.AssemblyAngularVelocity = Vector3.zero
                    end
                else
                    warn("You are not the ball owner → can't bring")
                end
            end
        end
    end
})

MiscSection:AddToggle({
    Name = "Ball Predictor (Line)",
    Flag = "MainSection_BallPredictor",
    Callback = function(Value)
        predictorEnabled = Value
        if not Value and predictionLine then
            predictionLine:Destroy()
            predictionLine = nil
        end
    end
})

PlayerSection:AddButton({
    Name = "Get Captain",
    Flag = "PlayerSection_GetCaptain",
    Callback = function(Value)
            local networkRemote = findRemote(HI_OBJECT_NAME)
            if networkRemote then
                networkRemote:FireServer(1000, "captain")
            end
        end
})

PlayerSection:AddButton({
    Name = "Pitch Teleporter",
    Callback = function()
        local networkRemote = findRemote(HI_OBJECT_NAME)
        if networkRemote then
            networkRemote:FireServer(1000, "pitchTeleporter")
        end
    end
})

PlayerSection:AddDropdown({
    Name = "Celebrations",
    List = {
        "None", "Fist Pump", "Right Here Right Now", "Tshabalala", "Archer Slide", "Point Up",
        "The Griddy", "Boxing", "Glorious", "Yoga", "Calma", "Shivering",
        "Folded Arms Knee Slide", "Gunleann", "Knockout", "Salute Knee Slide",
        "Meditation", "Ice Cold", "Catwalk", "Backflip", "Double Siuuu",
        "Prayerr", "Folded Arms", "Spanish Dance", "Pigeon", "Strange Dance"
    },
    Multi = false,
    Value = "None",
    Callback = function(selected)
        playAnimation(CELEBRATIONS[selected], "CelebrationAnim")
    end
})

AdminSection:AddButton({
    Name = "Ragdoll All",
    Callback = function(Value)
            for _, plr in pairs(Players:GetPlayers()) do
                if plr ~= LOCAL_PLAYER then
                    ragdollPlayer(plr)
                end
            end
        end
})

AdminSection:AddButton({
    Name = "UnRagdoll All",
    Callback = function(Value)
            for _, plr in pairs(Players:GetPlayers()) do
                unragdollPlayer(plr)
            end
        end
})

AdminSection:AddToggle({
    Name = "Speed Boost",
    Flag = "AdminSection_SpeedBoost",
    Callback = function(Value)
        tpWalking = Value
        if tpWalking then
            TOGGLE_CONNECTIONS.SpeedLoop = RunService.Heartbeat:Connect(function()
                local char = LOCAL_PLAYER.Character
                local hum = char and char:FindFirstChildWhichIsA("Humanoid")
                if tpWalking and char and hum and hum.Parent then
                    local delta = RunService.Heartbeat:Wait()
                    if hum.MoveDirection.Magnitude > 0 then
                        char:TranslateBy(hum.MoveDirection * moveSpeed * delta * 10)
                    end
                end
            end)
        else
            if TOGGLE_CONNECTIONS.SpeedLoop then
                TOGGLE_CONNECTIONS.SpeedLoop:Disconnect()
                TOGGLE_CONNECTIONS.SpeedLoop = nil
            end
        end
    end
})

AdminSection:AddSlider({
    Name = "Speed",
    Flag = "MainSection_Speed",
    Value = moveSpeed,
    Precise = 1,
    Min = 1,
    Max = 25,
    Callback = function(Value)
        moveSpeed = Value
    end
})


AdminSection:AddDropdown({
    Name = "Ragdoll Player",
    List = getPlayerNames(),
    Multi = false,
    Value = nil,
    Callback = function(selected)
        if selected then
            local targetPlayer = Players:FindFirstChild(selected)
            if targetPlayer then
                ragdollPlayer(targetPlayer)
            end
        end
    end
})

AdminSection:AddDropdown({
    Name = "Unragdoll Player",
    List = getPlayerNames(),
    Multi = false,
    Value = nil,
    Callback = function(selected)
        if selected then
            local targetPlayer = Players:FindFirstChild(selected)
            if targetPlayer then
                unragdollPlayer(targetPlayer)
            end
        end
    end
})

MiscSection:AddDropdown({
    Name = "Intensity",
    List = {"", "Light", "Moderate", "Heavy", "Violent"},
    Multi = false,
    Value = "",
    Callback = function(selectedValue)
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Intensity", selectedValue)
        end
    end
})

MiscSection:AddToggle({
    Name = "Enable Thunder",
    Callback = function(Value)
        local isEnabled = Value
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Thunder", isEnabled)
        end
    end
})

MiscSection:AddButton({
    Name = "FE Overcast",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Weather", "Overcast")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Rain",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Weather", "Rain")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Clear",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Weather", "Clear")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Snow",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Weather", "Snow")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Morning",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Time", "Morning")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Night",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Time", "Night")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Noon",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Time", "Noon")
        end
    end
})

MiscSection:AddButton({
    Name = "FE Afternoon",
    Callback = function()
        if remoteEvent then
            remoteEvent:FireServer(1000, "editMatchSettings", "idle", "Time", "Afternoon")
        end
    end
})

local WeatherConfig = ReplicatedStorage:FindFirstChild("game") and ReplicatedStorage.game:FindFirstChild("config") and ReplicatedStorage.game.config:FindFirstChild("Weather")
local function SetWeather(weather)
    if WeatherConfig and WeatherConfig:IsA("StringValue") then
        WeatherConfig.Value = weather
    end
end

MiscSection:AddButton({ Name = "Winter Mode", Callback = function() SetWeather("Snow") end })
MiscSection:AddButton({ Name = "Storm Mode", Callback = function() SetWeather("Rain") end })
MiscSection:AddButton({ Name = "Clear Skies", Callback = function() SetWeather("Clear") end })
MiscSection:AddButton({ Name = "Cloudy", Callback = function() SetWeather("Overcast") end })

local TimeConfig = ReplicatedStorage:FindFirstChild("game") and ReplicatedStorage.game:FindFirstChild("config") and ReplicatedStorage.game.config:FindFirstChild("Time")
local function SetTime(time)
    if TimeConfig and TimeConfig:IsA("StringValue") then
        TimeConfig.Value = time
    end
end

MiscSection:AddButton({ Name = "Day Mode", Callback = function() SetTime("Morning") end })
MiscSection:AddButton({ Name = "Night Mode", Callback = function() SetTime("Night") end })

    local function hasKickTool()
        return CHARACTER:FindFirstChild("Kick")
    end

    local function tweakPhysics(part)
        if part:IsA("BasePart") then
            local bodyVelocity = part:FindFirstChildOfClass("BodyVelocity")
            local bodyAngularVelocity = part:FindFirstChildOfClass("BodyAngularVelocity")

            if bodyVelocity then
                local currentVelocity = bodyVelocity.Velocity
                local verticalVelocity = Vector3.new(0, currentVelocity.Y, 0)
                local horizontalVelocity = currentVelocity - verticalVelocity

                local speedMultiplier = 50
                local newVelocity = horizontalVelocity * speedMultiplier + verticalVelocity * Y_AXIS_MULTIPLIER
                if newVelocity.Magnitude > MAX_VELOCITY then
                    newVelocity = newVelocity.Unit * MAX_VELOCITY
                end
                bodyVelocity.Velocity = newVelocity
            end
            if bodyAngularVelocity then
                bodyAngularVelocity.AngularVelocity = bodyAngularVelocity.AngularVelocity * 1
            end
        end
    end

    local function onBootOrFootTouched(otherPart)
        if hasKickTool() and otherPart:IsA("BasePart") and otherPart:FindFirstChild("network") then
            tweakPhysics(otherPart)
        end
    end
    
-- Power Shot toggle
AdminSection:AddToggle({
    Name = "Power Shot",
    Flag = "AdminSection_PowerShot",
    Callback = function(Value)
        if Value then
            local connections = {}
            local leftBoot = CHARACTER:WaitForChild("LeftBoot")
            local rightBoot = CHARACTER:WaitForChild("RightBoot")
            local leftFoot = CHARACTER:WaitForChild("LeftFoot")
            local rightFoot = CHARACTER:WaitForChild("RightFoot")

            local function onTouched(part)
                if CHARACTER:FindFirstChild("Kick") and part:IsA("BasePart") and part:FindFirstChild("network") then
                    local bodyVelocity = part:FindFirstChildOfClass("BodyVelocity")
                    if bodyVelocity then
                        local dir = bodyVelocity.Velocity.Unit
                        if dir.Magnitude == 0 then dir = Vector3.new(1,0,0) end
                        local newVel = dir * MAX_VELOCITY
                        newVel = Vector3.new(newVel.X, Y_AXIS_MULTIPLIER, newVel.Z)
                        bodyVelocity.Velocity = newVel
                    end
                end
            end

            connections.leftBoot = leftBoot.Touched:Connect(onTouched)
            connections.rightBoot = rightBoot.Touched:Connect(onTouched)
            connections.leftFoot = leftFoot.Touched:Connect(onTouched)
            connections.rightFoot = rightFoot.Touched:Connect(onTouched)

            TOGGLE_CONNECTIONS.PowerShot = connections
        else
            if TOGGLE_CONNECTIONS.PowerShot then
                for _, conn in pairs(TOGGLE_CONNECTIONS.PowerShot) do
                    conn:Disconnect()
                end
                TOGGLE_CONNECTIONS.PowerShot = nil
            end
        end
    end
})

-- Shot Power slider
AdminSection:AddSlider({
    Name = "Shot Power",
    Flag = "AdminSection_ShotPower",
    Value = MAX_VELOCITY,
    Precise = 1,
    Min = 0,
    Max = 500,
    Callback = function(Value)
        MAX_VELOCITY = Value
    end
})

-- Vertical Boost slider
AdminSection:AddSlider({
    Name = "Vertical Boost",
    Flag = "AdminSection_VerticalBoost",
    Value = Y_AXIS_MULTIPLIER,
    Precise = 1,
    Min = 0,
    Max = 100,
    Callback = function(Value)
        Y_AXIS_MULTIPLIER = Value
    end
})
MainSection:AddTextbox({
    Name = "Reach XYZ",
    Flag = "MainSection_ReachXYZ",
    Value = tostring(REACH_X) .. "," .. tostring(REACH_Y) .. "," .. tostring(REACH_Z),
    Callback = function(Text)
        -- Parse input like "10,20,30"
        local x, y, z = Text:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
        if x and y and z then
            REACH_X, REACH_Y, REACH_Z = tonumber(x), tonumber(y), tonumber(z)
            print("Reach updated → X:", REACH_X, " Y:", REACH_Y, " Z:", REACH_Z)
        else
            warn("Invalid format. Use: X,Y,Z (example: 10,20,30)")
        end
    end
})
