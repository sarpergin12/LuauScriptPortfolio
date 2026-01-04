--!strict

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// MODULE DECLARATION
local ViewportManager = {}

--// INTERNAL STATE & ENGINES
local ROTATION_SPEED = 50
local RETURN_TIME = 0.4
local currentlyHoveredVpf: ViewportFrame? = nil

local defaultCFrames: {[ViewportFrame]: CFrame} = {}
local draggableConnections: {[ViewportFrame]: {RBXScriptConnection}} = {}
local activeReturnTweens: {[ViewportFrame]: Tween} = {}


--// FORWARD DECLARE THE OPTIONS TYPE FOR HELPER FUNCTIONS
export type CreateOptions = {
	Parent: GuiObject,
	ItemData: {[string]: any},
	Model: Model?,
	IsOwned: boolean,
	Viewport : ViewportFrame?,
	HoverDisabled : boolean?,
	EnableDrag: boolean?
}

-- Creates a draggable viewport
local function createDraggableViewport(options: CreateOptions)
	local viewport = options.Viewport or Instance.new("ViewportFrame")
	if not options.Viewport then
		viewport.Size = UDim2.fromScale(1, 1)
	end
	viewport.Parent = options.Parent

	-- Setup WorldModel, Camera, and Effects
	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local camera = Instance.new("Camera")
	camera.CameraType = Enum.CameraType.Scriptable
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Brightness = 0.1
	colorCorrection.Contrast = 0.15
	colorCorrection.Saturation = 0.1
	colorCorrection.Parent = viewport

	local clone : Model
	local modelSize: Vector3
	local modelCenter: Vector3

	-- Model/Animation Handling
	if options.Model then
		camera.FieldOfView = 45
		clone = options.Model:Clone()
		clone.Parent = world

		if not clone.PrimaryPart then
			clone.PrimaryPart = clone:FindFirstChildWhichIsA("BasePart")
		end

		local cf, size = clone:GetBoundingBox()
		modelSize = size
		modelCenter = cf.Position
		local facing = (options.ItemData.DualWield == true) and CFrame.Angles(0, math.rad(65), 0) or CFrame.Angles(0, math.rad(-115), 0)
		clone:PivotTo(CFrame.new(-modelCenter) * facing)
		modelCenter = clone:GetPivot().Position
	end

	-- Advanced Lighting
	if options.IsOwned then
		viewport.BackgroundColor3 = Color3.fromRGB(156, 156, 156)
		viewport.LightColor = Color3.fromRGB(232, 232, 232)
		viewport.Ambient = Color3.fromRGB(255, 255, 255)
	else
		viewport.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		viewport.LightColor = Color3.fromRGB(12, 12, 12)
		viewport.Ambient = Color3.fromRGB(8, 8, 8)
	end

	local function createLight(parent: Instance, name: string, pos: Vector3, brightness: number, range: number, color: Color3?)
		local part = Instance.new("Part", parent)
		part.Name = name; part.Transparency = 1; part.Anchored = true; part.CanCollide = false
		part.Size = Vector3.one; part.Position = pos
		local light = Instance.new("PointLight", part)
		light.Brightness = brightness; light.Range = range
		if color then light.Color = color end
	end

	local lightRig = Instance.new("Model", clone)
	lightRig.Name = "LightRig"
	createLight(lightRig, "KeyLight", modelCenter + Vector3.new(4, 3, 5), 2, 30, Color3.fromRGB(255, 245, 230))
	createLight(lightRig, "FillLight", modelCenter + Vector3.new(-4, 2, 5), 1.5, 30, Color3.fromRGB(230, 240, 255))
	createLight(lightRig, "RimLight", modelCenter + Vector3.new(0, 1, -6), 1.8, 30, Color3.fromRGB(255, 255, 255))
	createLight(lightRig, "UnderLight", modelCenter + Vector3.new(0, -5, 2), 1.2, 30)

	-- Dynamic Zoom & Camera Positioning
	local modelRadius = math.max(modelSize.X, modelSize.Y, modelSize.Z) / 2
	local zoomMultiplier = (options.ItemData.DualWield and 1.4) or (options.ItemData.Type == "WinAnimation" and 1.5) or 0.9
	local zoom = (modelRadius * zoomMultiplier) / math.tan(math.rad(camera.FieldOfView / 2))
	local minZoom = zoom * 0.5
	local maxZoom = zoom * 2.5

	-- Rotation and Input State
	local yaw, pitch = 0, 0
	local pitchLimits = NumberRange.new(math.rad(-60), math.rad(60))
	local dragging = false

	local function updateCamera()
		pitch = math.clamp(pitch, pitchLimits.Min, pitchLimits.Max)
		camera.CFrame = CFrame.Angles(pitch, yaw, 0) * CFrame.new(0, 0, zoom) + modelCenter
	end
	updateCamera()

	-- Store all connections for later cleanup
	local connections = {}
	draggableConnections[viewport] = connections

	-- Floating animation
	local t = 0
	local initialPivot = clone:GetPivot()
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		t += dt
		if clone and clone.Parent and not dragging and options.ItemData.Type ~= "WinAnimation" then
			local lift = math.sin(t * 1.5) * 0.075
			clone:PivotTo(initialPivot * CFrame.new(0, lift, 0))
		end
	end))

	-- Input Handling
	table.insert(connections, viewport.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))

	table.insert(connections, viewport.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end))

	table.insert(connections, RunService.RenderStepped:Connect(function(dt)
		if dragging then
			local delta = UserInputService:GetMouseDelta()
			yaw -= delta.X * 0.01
			pitch -= delta.Y * 0.01
		else
			local returnSpeed = 7
			yaw = yaw + (0 - yaw) * returnSpeed * dt
			pitch = pitch + (0 - pitch) * returnSpeed * dt
			if math.abs(yaw) < 0.001 then yaw = 0 end
			if math.abs(pitch) < 0.001 then pitch = 0 end
		end
		updateCamera()
	end))

	table.insert(connections, viewport.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoom = math.clamp(zoom - input.Position.Z * (modelRadius * 0.05), minZoom, maxZoom)
			updateCamera()
		end
	end))

	return viewport
end

RunService.Heartbeat:Connect(function(deltaTime: number)
	if currentlyHoveredVpf then
		local world = currentlyHoveredVpf:FindFirstChildOfClass("WorldModel")
		if not world then return end
		local model = world:FindFirstChildOfClass("Model")
		-- Only rotate if the model exists and isn't currently tweening back to its default state.
		if model and not activeReturnTweens[currentlyHoveredVpf] then
			local rotationAmount = CFrame.Angles(0, math.rad(ROTATION_SPEED * deltaTime), 0)
			model:PivotTo(rotationAmount * model:GetPivot())
		end
	end
end)

local function onHoverLeave(viewport: ViewportFrame)
	-- If a return tween is already playing, don't start another one.
	if activeReturnTweens[viewport] then return end

	local world = viewport:FindFirstChildOfClass("WorldModel")
	if not world then return end
	local model = world:FindFirstChildOfClass("Model")
	if not (model and defaultCFrames[viewport]) then return end

	local cframeProxy = Instance.new("CFrameValue")
	cframeProxy.Value = model:GetPivot()
	local connection: RBXScriptConnection
	connection = cframeProxy.Changed:Connect(function(newPivot)
		if model and model.Parent then model:PivotTo(newPivot) end
	end)

	local tween = TweenService:Create(cframeProxy, TweenInfo.new(RETURN_TIME, Enum.EasingStyle.Sine), {Value = defaultCFrames[viewport]})

	-- Track the active tween so it can be cancelled if needed.
	activeReturnTweens[viewport] = tween

	tween.Completed:Connect(function()
		-- Stop tracking the tween once it has finished.
		activeReturnTweens[viewport] = nil
		connection:Disconnect()
		cframeProxy:Destroy()
	end)
	tween:Play()
end


--// PUBLIC API
function ViewportManager.create(options: CreateOptions): GuiObject

	local parentButton = options.Parent
	local itemData = options.ItemData

	--// ITEM USES A 2D IMAGE
	if itemData.UseImage then
		local imageLabel = Instance.new("ImageLabel")
		imageLabel.Name = "ItemImage"
		imageLabel.Image = itemData.IconID or ""
		imageLabel.BackgroundTransparency = 1
		imageLabel.Size = UDim2.fromScale(1, 1)
		imageLabel.Parent = parentButton
		return imageLabel
	end

	--// ITEM USES A 3D VIEWPORT
	if options.EnableDrag then
		-- ADVANCED DRAGGABLE VIEWPORT
		return createDraggableViewport(options)
	else
		-- STANDARD HOVER-ROTATE VIEWPORT
		local itemModel = options.Model
		local isOwned = options.IsOwned
		local hoverDisabled = options.HoverDisabled

		local viewport = options.Viewport or Instance.new("ViewportFrame")
		if not options.Viewport then
			viewport.Size = UDim2.fromScale(1, 1)
		end
		viewport.BackgroundTransparency = 1
		viewport.Parent = parentButton

		local world = Instance.new("WorldModel")
		world.Parent = viewport

		local camera = Instance.new("Camera")
		camera.Parent = viewport
		viewport.CurrentCamera = camera

		local clone: Model

		if itemModel then
			camera.FieldOfView = 40
			clone = itemModel:Clone()
			clone.Parent = world

			clone:PivotTo(CFrame.new())
			local cf, size = clone:GetBoundingBox()
			local facing = (itemData.DualWield == true) and CFrame.Angles(0, math.rad(35), 0)
				or itemData.Contract and CFrame.Angles(math.rad(60), math.rad(15), math.rad(-30)) or CFrame.Angles(0, math.rad(-115), 0)
			clone:PivotTo(facing)

			defaultCFrames[viewport] = clone:GetPivot()

			local distance = (size.Magnitude / 2.2) / math.tan(math.rad(camera.FieldOfView / 2))
			camera.CFrame = CFrame.new(cf.Position + Vector3.new(0, 0, distance), cf.Position)
		end

		if isOwned then
			viewport.LightColor = Color3.fromRGB(232, 232, 232)
			viewport.Ambient = Color3.fromRGB(255, 255, 255)
		else
			viewport.LightColor = Color3.fromRGB(25, 25, 25)
			viewport.Ambient = Color3.fromRGB(60, 60, 60)
		end

		if itemModel and not hoverDisabled then
			-- Mouse event logic for flicker-free transitions
			parentButton.MouseEnter:Connect(function()
				-- If a "return" tween is playing, cancel it immediately to prevent flickering.
				if activeReturnTweens[viewport] then
					activeReturnTweens[viewport]:Cancel()
					activeReturnTweens[viewport] = nil
				end
				-- Set this viewport as the one to be rotated by the central Heartbeat connection.
				currentlyHoveredVpf = viewport
			end)

			parentButton.MouseLeave:Connect(function()
				-- Only trigger the "leave" logic if the mouse is leaving THIS specific viewport.
				-- This prevents issues when moving quickly between two viewports.
				if currentlyHoveredVpf == viewport then
					currentlyHoveredVpf = nil
					onHoverLeave(viewport)
				end
			end)
		end

		return viewport
	end
end

function ViewportManager.cleanup(parentButton: GuiObject, preserveViewport : boolean?)
	if not parentButton then return end

	local viewport = parentButton:FindFirstChildOfClass("ViewportFrame")
	local image = parentButton:FindFirstChild("ItemImage")

	if viewport then
		-- Cancel any active return tween during cleanup.
		if activeReturnTweens[viewport] then
			activeReturnTweens[viewport]:Cancel()
			activeReturnTweens[viewport] = nil
		end

		-- Cleanup for standard hover-rotate viewports
		defaultCFrames[viewport] = nil
		if viewport == currentlyHoveredVpf then
			currentlyHoveredVpf = nil
		end

		-- Cleanup for advanced draggable viewports
		if draggableConnections[viewport] then
			for _, conn in ipairs(draggableConnections[viewport]) do
				conn:Disconnect()
			end
			draggableConnections[viewport] = nil -- Clear the entry
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end

		if not preserveViewport then
			viewport:Destroy()
		elseif preserveViewport then
			viewport:ClearAllChildren()
		end
	end

	if image then
		image:Destroy()
	end
end

return ViewportManager
