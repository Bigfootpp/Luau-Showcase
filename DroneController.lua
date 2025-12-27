local Drone = {}
Drone.__index = Drone

--// Services
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local TS = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Ran = Random.new()

--// Assets
-- The template is a Part Instance and not a Model
local Template = script.DroneModel
local BoltPart = script.BoltPart
local Highlight = script.Highlight
local LightEvent = RS.Events.ToggleLight

--// Types
export type DroneSettings = {
	YOffset: number,
	Range: number,
	LightningDuration: number,
	PointCount: number,
	XZLightningOffset: number,
	FireRate: number,
	MaxTilt: number,
}

--// Settings
-- This is the default settings for the drone if no specific settings.
-- This variable allows us to change the default settings without modifying the code
local DefaultSettings: DroneSettings = {
	YOffset = 6,
	Range = 30,
	LightningDuration = 0.3,
	PointCount = 20,
	XZLightningOffset = 2,
	FireRate = 1,
	MaxTilt = 20,
}

-- Create a part between two Vectors
local function CreatePart(startPos, endPos)
	local newBolt = BoltPart:Clone()
	local dist = (startPos - endPos).Magnitude

	newBolt.Size = Vector3.new(0.15, 0.15, dist)
	
	-- We Rotate the part to look at the target position then set its position in the middle of the two points
	-- This makes the part link eachother
	newBolt.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -newBolt.Size.Z / 2)
	
	newBolt.Parent = workspace

	return newBolt
end

-- Create a new drone object
-- It allows to handle multiple drone and use their functions
function Drone.New(player: Player, data: DroneSettings)
	local self = setmetatable({}, Drone)
	
	--// Instance variables
	-- Can be used in method
	self.Owner = player
	self.Config = data or DefaultSettings
	self.Heartbeat = nil
	self.LastFire = 0
	self.connections = {}
	
	-- // Create the drone model
	local model = Template:Clone()
	model.Name = player.Name .. "_Drone"
	self.Model = model
	
	-- Make sure that the character exist to prevent error
	if not player.Character then
		player.CharacterAdded:Wait()
	end

	local hrp = player.Character:WaitForChild("HumanoidRootPart")
	
	-- Set the drone position to the player position + Y offset
	if hrp then
		local startCF = hrp.CFrame * CFrame.new(0, self.Config.YOffset, 0)
		model.CFrame = startCF
	end

	model.Parent = workspace
	
	-- Detect when the player want to toggle the light (E key)
	local lightConn = LightEvent.OnServerEvent:Connect(function(plr)
		-- Check if the player is the owner of the drone
		if plr == self.Owner then
			self:ToggleLight()
		end
	end)
	
	-- Add the connection to the list of connection to make sure there is no event left when the drone is destroyed
	table.insert(self.connections, lightConn)
	
	-- Sets the network owner of the drone to the player
	-- This allows to have less latency and make the drone more responsive
	if model:CanSetNetworkOwnership() then
		model:SetNetworkOwner(player)
	end

	return self
end

-- Start the main loop of the drone
function Drone:Start()
	-- Check if there is already a loop if yes stop the loop
	if self.Heartbeat then self.Heartbeat:Disconnect() end
	
	-- Create a new loop to update every frame
	self.Heartbeat = RunService.Heartbeat:Connect(function()
		self:Update()
	end)
end

-- Run every frame and handle movement and logic 
function Drone:Update()
	-- Check if the drone model exist, if not destroy the drone
	if not self.Model or not self.Model.Parent then
		self:Destroy()
		return
	end
	
	local char = self.Owner.Character
	if not char then return end
	
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local currentPos = hrp.Position
	local height = self.Config.YOffset
	local targetPos = Vector3.new(currentPos.X, currentPos.Y + height, currentPos.Z)

	local target = CFrame.new(targetPos) * hrp.CFrame.Rotation
	self:Move(target)
	
	-- Check the cooldown from the last shot before try to shoot
	local now = os.clock()
	if now - self.LastFire > self.Config.FireRate then
		self:Shoot()
	end
end

-- Find the target, make the visual effect (lighning, highlight)
-- and then destroy the target
function Drone:Shoot()
	local origin = self.Model.Position
	-- Find the best target
	local target = self:FindTarget()
	
	if target then
		-- Manage the cooldown by resetting the last shot time
		self.LastFire = os.clock()
		
		-- Play visual effect so the player know when he hits a target
		self:CreateLightning(target.Position)
		self:CreateHighlight(target)
		
		-- Destroy the target
		-- We use task.delay to sync with the visual effect
		-- This makes the attack more smooth and not destroy the target instantly when the lightning hit
		task.delay(self.Config.LightningDuration, function()
			-- Make sure that the target still exist before destroy the target
			if target and target.Parent then
				self:Hit(target)
			end
		end)
	end
end

-- Find the best target by using raycast and find the closest target
function Drone:FindTarget()
	local origin = self.Model.Position
	local maxRange = self.Config.Range
	local bestTarget = nil

	local targets = CS:GetTagged("target")
	
	-- Exclude the drone and the player from the raycast to prevent to hit the drone or the player
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {self.Model, self.Owner.Character}
	params.FilterType = Enum.RaycastFilterType.Exclude
	
	for _, part in ipairs(targets) do
		local mag = (part.Position - origin).Magnitude

		if mag < maxRange then
			
			-- We use raycast to make sure that the target is not blocked by other objects
			local dir = part.Position - origin
			local ray = workspace:Raycast(origin, dir, params)
			
			-- Make sure that the ray hit the target or hit another valid target
			if ray and ray.Instance:IsDescendantOf(part.Parent) then
				maxRange = mag
				bestTarget = part
			end
		end
	end

	return bestTarget
end

-- Generate a random procedural lightning effect between the drone and a vector
function Drone:CreateLightning(endPos: Vector3)
	local startPos = self.Model.Position
	local points = self.Config.PointCount
	local offset = self.Config.XZLightningOffset

	local lastPoint = startPos
	
	-- Create the tween info to make the lightning fade out after destroying the target
	local TI = TweenInfo.new(self.Config.LightningDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	
	for i = 1, points do
		-- Calculate the alpha to represent the progress
		local alpha = i / points
		
		-- Calculate the target vector
		local targetPoint = startPos:Lerp(endPos, alpha)
		
		-- Check if the current point is not the last point to make sure
		-- that the last point is not affected by the offset and hit the target
		if i ~= points then
			-- Add a random offset to the target vector to create a lightning effect
			local offset = Vector3.new(
				math.random(-offset, offset) / 10,
				math.random(-offset, offset) / 10,
				math.random(-offset, offset) / 10
			)
			targetPoint = targetPoint + offset
		end
		
		-- Create a part between points
		local part = CreatePart(lastPoint, targetPoint)
		
		-- Make the part fade out after destroying the target
		task.delay(self.Config.LightningDuration, function()
			local tween = TS:Create(part, TI, {Transparency = 1})
			tween:Play()
			Debris:AddItem(part, self.Config.LightningDuration)
		end)

		lastPoint = targetPoint
	end
end

-- Make the target highlight before destroying the target
function Drone:CreateHighlight(target: Instance)
	local newHighlight = Highlight:Clone()
	newHighlight.Parent = target
	newHighlight.Adornee = target
	Debris:AddItem(newHighlight, self.Config.LightningDuration)
end

-- Destroy the target with an explosion effect
function Drone:Hit(target: Instance)
	-- Make an explosion effect
	local exp = Instance.new("Explosion")
	exp.Position = target.Position
	exp.BlastRadius = 0
	exp.BlastPressure = 0
	exp.Parent = workspace
	
	-- Destroy the target
	target:Destroy()
end

-- Toggle the light of the drone
function Drone:ToggleLight()
	local light = self.Model:FindFirstChild("Light")
	if light then
		light.Enabled = not light.Enabled
	end
end


-- Move the drone to the target using the AlignPosition and AlignOrientation
-- and make a tilt effect to make the drone look like a real drone
function Drone:Move(targetCframe: CFrame)
	local alignPos = self.Model:FindFirstChild("AlignPosition")
	local alignRot = self.Model:FindFirstChild("AlignOrientation")
	
	-- Sensitivity settings
	local tiltSens = 0.05
	local maxTilt = math.rad(self.Config.MaxTilt) -- Convert the max tilt degrees to radians

	if alignPos and alignRot then
		
		-- Set the AlignPosition position to make the drone move more smoothly
		alignPos.Position = targetCframe.Position
		
		local currentVel = self.Model.AssemblyLinearVelocity
		
		-- Convert the World space velocity to Local space velocity
		-- This allows us to know if the drone is going forward, backward, left, right, up and down
		-- from where the drone is facing
		local relativeVel = self.Model.CFrame:VectorToObjectSpace(currentVel)
		
		-- Calculate the tilt angles based by the local space velocity
		local forwardTilt = relativeVel.Z * tiltSens
		local sideTilt = -relativeVel.X * tiltSens
		
		-- Prevent the drone to flip by clamping to a certain angle
		forwardTilt = math.clamp(forwardTilt, -maxTilt, maxTilt)
		sideTilt = math.clamp(sideTilt, -maxTilt, maxTilt)
		
		-- Get the Y axis from target CFrame to rotate the correct direction
		local _, targetY, _ = targetCframe:ToOrientation()
		
		-- Combine the tilt angles and the Y axis
		alignRot.CFrame = CFrame.new(targetCframe.Position) * CFrame.fromOrientation(forwardTilt, targetY, sideTilt)
	else
		-- If there is no Align Position or Orientation then just update the Cframe
		local current = self.Model.CFrame
		self.Model.CFrame = targetCframe
	end
end

-- Destroy the drone when the character is destroyed (the player die or leave) and clean up memory
function Drone:Destroy()
	-- Stop the main loop to prevent any updates
	if self.Heartbeat then
		self.Heartbeat:Disconnect()
		self.Heartbeat = nil
	end
	
	-- Disconnect all the connections
	for _, c in ipairs(self.connections) do
		c:Disconnect()
	end
	self.connections = {}
	
	-- Destroy the model by making it fade out and then destroy it
	if self.Model then
		local alignPos = self.Model:FindFirstChild("AlignPosition")
		local alignRot = self.Model:FindFirstChild("AlignOrientation")
		
		if alignPos and alignRot then
			-- Create the tween to make the drone disappear
			local TI = TweenInfo.new(5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
			local tween = TS:Create(self.Model, TI, {Transparency = 1})
			
			-- Disable the constraints to make the drone fall down
			alignPos.Enabled = false
			alignRot.Enabled = false
			
			self.Model.CanCollide = true
			
			-- Play the tween and then destroy the model
			tween:Play()
			Debris:AddItem(self.Model, TI.Time)
		else
			self.Model:Destroy()
		end
	end
	
	-- Destroy the instance
	setmetatable(self, nil)
end

return Drone
