--!strict

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ViewportManager = {}

-- Constant configuration for a uniform UI feel across the app
local ROTATION_SPEED = 50 
local RETURN_TIME = 0.4 

-- Tracking tables: We use the ViewportFrame instance as the key.
-- This allows us to map specific data/connections to specific UI elements without mixing them up.
local currentlyHoveredVpf: ViewportFrame? = nil
local defaultCFrames: {[ViewportFrame]: CFrame} = {} 
local draggableConnections: {[ViewportFrame]: {RBXScriptConnection}} = {} 
local activeReturnTweens: {[ViewportFrame]: Tween} = {} 

export type CreateOptions = {
	Parent: GuiObject,
	ItemData: {[string]: any},
	Model: Model?,
	IsOwned: boolean,
	Viewport : ViewportFrame?,
	HoverDisabled : boolean?,
	EnableDrag: boolean?
}

-- Setup for the inspection view (where players can rotate/zoom the item)
local function createDraggableViewport(options: CreateOptions)
	local viewport = options.Viewport or Instance.new("ViewportFrame")
	if not options.Viewport then
		viewport.Size = UDim2.fromScale(1, 1)
	end
	viewport.Parent = options.Parent

	-- We use WorldModel because it allows us to run physics/animations 
	-- inside the ViewportFrame, which a standard Folder doesn't support well.
	local world = Instance.new("WorldModel")
	world.Parent = viewport

	-- Camera is Scriptable so we can manually calculate its position in 3D space
	local camera = Instance.new("Camera")
	camera.CameraType = Enum.CameraType.Scriptable
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	-- Post-processing: Boosting contrast/brightness makes models pop against dark UI backgrounds
	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Brightness = 0.1
	colorCorrection.Contrast = 0.15
	colorCorrection.Saturation = 0.1
	colorCorrection.Parent = viewport

	local clone : Model
	local modelSize: Vector3
	local modelCenter: Vector3

	if options.Model then
		camera.FieldOfView = 45
		clone = options.Model:Clone()
		clone.Parent = world

		-- PrimaryPart is essential for PivotTo logic; fallback to first part found
		if not clone.PrimaryPart then
			clone.PrimaryPart = clone:FindFirstChildWhichIsA("BasePart")
		end

		-- GetBoundingBox gives us the size and world-center of the model.
		-- This is crucial for centering the camera so the model doesn't "wobble" when rotating.
		local cf, size = clone:GetBoundingBox()
		modelSize = size
		modelCenter = cf.Position
		
		-- Adjust initial rotation based on weapon type so the "best" side faces the player
		local facing = (options.ItemData.DualWield == true) and CFrame.Angles(0, math.rad(65), 0) or CFrame.Angles(0, math.rad(-115), 0)
		clone:PivotTo(CFrame.new(-modelCenter) * facing)
		modelCenter = clone:GetPivot().Position
	end

	-- Darken lighting for unowned items, brighten for owned ones.
	if options.IsOwned then
		viewport.BackgroundColor3 = Color3.fromRGB(156, 156, 156)
		viewport.LightColor = Color3.fromRGB(232, 232, 232)
		viewport.Ambient = Color3.fromRGB(255, 255, 255)
	else
		viewport.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		viewport.LightColor = Color3.fromRGB(12, 12, 12)
		viewport.Ambient = Color3.fromRGB(8, 8, 8)
	end

	-- Dynamic light rig: We use multiple point lights to create depth (shadows/highlights)
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

	-- Distance Calc: Uses trigonometry to ensure the model fits perfectly in the frame.
	-- We divide the radius by the tangent of half the FOV to find the adjacent side (distance).
	local modelRadius = math.max(modelSize.X, modelSize.Y, modelSize.Z) / 2
	local zoomMultiplier = (options.ItemData.DualWield and 1.4) or (options.ItemData.Type == "WinAnimation" and 1.5) or 0.9
	local zoom = (modelRadius * zoomMultiplier) / math.tan(math.rad(camera.FieldOfView / 2))
	local minZoom, maxZoom = zoom * 0.5, zoom * 2.5

	local yaw, pitch = 0, 0
	local pitchLimits = NumberRange.new(math.rad(-60), math.rad(60))
	local dragging = false

	-- Updates the camera CFrame by rotating the offset vector (zoom) around the center point.
	local function updateCamera()
		pitch = math.clamp(pitch, pitchLimits.Min, pitchLimits.Max)
		camera.CFrame = CFrame.Angles(pitch, yaw, 0) * CFrame.new(0, 0, zoom) + modelCenter
	end
	updateCamera()

	-- Store connections so we can kill them later—crucial for preventing "ghost" loops.
	local connections = {}
	draggableConnections[viewport] = connections

	-- Add a sine-wave hover to the model to make the UI feel less static.
	local t = 0
	local initialPivot = clone:GetPivot()
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		t += dt
		if clone and clone.Parent and not dragging and options.ItemData.Type ~= "WinAnimation" then
			local lift = math.sin(t * 1.5) * 0.075
			clone:PivotTo(initialPivot * CFrame.new(0, lift, 0))
		end
	end))

	-- Lock the mouse when dragging so the player can keep rotating without the cursor hitting the screen edge.
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

	-- Map mouse movement (Delta) to world-space rotation (Yaw/Pitch).
	table.insert(connections, RunService.RenderStepped:Connect(function(dt)
		if dragging then
			local delta = UserInputService:GetMouseDelta()
			yaw -= delta.X * 0.01
			pitch -= delta.Y * 0.01
		else
			-- Smoothing: Return to original viewing angle when user lets go.
			local returnSpeed = 7
			yaw = yaw + (0 - yaw) * returnSpeed * dt
			pitch = pitch + (0 - pitch) * returnSpeed * dt
			if math.abs(yaw) < 0.001 then yaw = 0 end
			if math.abs(pitch) < 0.001 then pitch = 0 end
		end
		updateCamera()
	end))

	-- Mouse wheel input directly modifies the 'zoom' variable used in updateCamera.
	table.insert(connections, viewport.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoom = math.clamp(zoom - input.Position.Z * (modelRadius * 0.05), minZoom, maxZoom)
			updateCamera()
		end
	end))

	return viewport
end

-- Optimization: One Heartbeat connection handles ALL viewports.
-- We only process the viewport that the mouse is currently over to save CPU cycles.
RunService.Heartbeat:Connect(function(deltaTime: number)
	if currentlyHoveredVpf then
		local world = currentlyHoveredVpf:FindFirstChildOfClass("WorldModel")
		if not world then return end
		local model = world:FindFirstChildOfClass("Model")
		
		-- Rotation check: Don't rotate if the model is currently being tweened back to center.
		if model and not activeReturnTweens[currentlyHoveredVpf] then
			local rotationAmount = CFrame.Angles(0, math.rad(ROTATION_SPEED * deltaTime), 0)
			model:PivotTo(rotationAmount * model:GetPivot())
		end
	end
end)

-- Smoothly resets orientation.
-- Since you can't tween a Model's pivot directly, we tween a CFrameValue 
-- and update the model pivot on every frame of that tween.
local function onHoverLeave(viewport: ViewportFrame)
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
	activeReturnTweens[viewport] = tween

	-- Cleanup: disconnect the proxy listener once the tween is finished.
	tween.Completed:Connect(function()
		activeReturnTweens[viewport] = nil
		connection:Disconnect()
		cframeProxy:Destroy()
	end)
	tween:Play()
end


function ViewportManager.create(options: CreateOptions): GuiObject
	local parentButton = options.Parent
	local itemData = options.ItemData

	-- If the item data specifies a 2D icon, skip 3D rendering entirely to save performance.
	if itemData.UseImage then
		local imageLabel = Instance.new("ImageLabel")
		imageLabel.Name = "ItemImage"
		imageLabel.Image = itemData.IconID or ""
		imageLabel.BackgroundTransparency = 1
		imageLabel.Size = UDim2.fromScale(1, 1)
		imageLabel.Parent = parentButton
		return imageLabel
	end

	if options.EnableDrag then
		return createDraggableViewport(options)
	else
		-- Default Viewport (Auto-rotates on hover)
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
			
			-- Angle adjustments depending on itemData
			local facing = (itemData.DualWield == true) and CFrame.Angles(0, math.rad(35), 0)
				or itemData.Contract and CFrame.Angles(math.rad(60), math.rad(15), math.rad(-30)) or CFrame.Angles(0, math.rad(-115), 0)
			clone:PivotTo(facing)

			-- Save initial orientation for the reset-tween later.
			defaultCFrames[viewport] = clone:GetPivot()

			-- Positioning the camera based on model magnitude so nothing is "cutoff" the frame.
			local distance = (size.Magnitude / 2.2) / math.tan(math.rad(camera.FieldOfView / 2))
			camera.CFrame = CFrame.new(cf.Position + Vector3.new(0, 0, distance), cf.Position)
		end

		-- Lighting contrast helps separate "locked" items from "unlocked" ones visually.
		if isOwned then
			viewport.LightColor = Color3.fromRGB(232, 232, 232)
			viewport.Ambient = Color3.fromRGB(255, 255, 255)
		else
			viewport.LightColor = Color3.fromRGB(25, 25, 25)
			viewport.Ambient = Color3.fromRGB(60, 60, 60)
		end

		if itemModel and not hoverDisabled then
			parentButton.MouseEnter:Connect(function()
				-- Stop any active "reset" tweens if the mouse re-enters.
				if activeReturnTweens[viewport] then
					activeReturnTweens[viewport]:Cancel()
					activeReturnTweens[viewport] = nil
				end
				currentlyHoveredVpf = viewport
			end)

			parentButton.MouseLeave:Connect(function()
				-- Only trigger the leave logic for the specific viewport being exited.
				if currentlyHoveredVpf == viewport then
					currentlyHoveredVpf = nil
					onHoverLeave(viewport)
				end
			end)
		end

		return viewport
	end
end

-- Cleanup: This is arguably the most important part of the module.
-- It wipes all table references and kills script connections so the Garbage Collector can free up RAM.
function ViewportManager.cleanup(parentButton: GuiObject, preserveViewport : boolean?)
	if not parentButton then return end

	local viewport = parentButton:FindFirstChildOfClass("ViewportFrame")
	local image = parentButton:FindFirstChild("ItemImage")

	if viewport then
		-- Kill any tweens currently modifying the model to prevent errors on destroyed objects.
		if activeReturnTweens[viewport] then
			activeReturnTweens[viewport]:Cancel()
			activeReturnTweens[viewport] = nil
		end

		-- Clear state table references
		defaultCFrames[viewport] = nil
		if viewport == currentlyHoveredVpf then
			currentlyHoveredVpf = nil
		end

		-- Disconnect all input listeners stored for this specific viewport.
		if draggableConnections[viewport] then
			for _, conn in ipairs(draggableConnections[viewport]) do
				conn:Disconnect()
			end
			draggableConnections[viewport] = nil 
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end

		if not preserveViewport then
			viewport:Destroy()
		elseif preserveViewport then
			-- If we keep the viewport (recycling UI), clear children to remove the old WorldModel/Lights.
			viewport:ClearAllChildren()
		end
	end

	if image then
		image:Destroy()
	end
end

return ViewportManager
