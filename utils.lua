local utils = {}

-- a script to simplify trained net by incorporating every Spatial/VolumetricBatchNormalization
-- to Spatial/VolumetricConvolution and BatchNormalization to Linear
local function BNtoConv(net)
  for i,v in ipairs(net.modules) do
    if v.modules then
      BNtoConv(v)
    else
      local cur = v
      local pre = net:get(i-1)
      if pre and 
        ((torch.typename(cur):find'nn.SpatialBatchNormalization' and 
          torch.typename(pre):find'nn.SpatialConvolution') or
         (torch.typename(cur):find'nn.BatchNormalization' and
          torch.typename(pre):find'nn.Linear') or
         (torch.typename(cur):find'nn.VolumetricBatchNormalization' and 
          torch.typename(pre):find'nn.VolumetricConvolution')) then
        local conv = pre
        local bn = v
        net:remove(i)
        local no = conv.nOutputPlane
        local conv_w = conv.weight:view(no,-1)
        local fold = function()
           local invstd = bn.running_var and (bn.running_var + bn.eps):pow(-0.5) or bn.running_std
           if not conv.bias then
              conv.bias = bn.running_mean:clone():zero()
              conv.gradBias = conv.bias:clone()
           end
          conv_w:cmul(invstd:view(no,-1):expandAs(conv_w))
          conv.bias:add(-1,bn.running_mean):cmul(invstd)
          if bn.affine then
            conv.bias:cmul(bn.weight):add(bn.bias)
            conv_w:cmul(bn.weight:view(no,-1):expandAs(conv_w))
          end
          if conv.resetWeightDescriptors then
             conv:resetWeightDescriptors()
             assert(conv.biasDesc)
          end
        end
        if cutorch then cutorch.withDevice(conv_w:getDevice(),fold) else fold() end
      end
    end
  end
end

local checklist = {
  'nn.SpatialBatchNormalization',
  'nn.VolumetricBatchNormalization',
  'nn.BatchNormalization',
  'cudnn.SpatialBatchNormalization',
  'cudnn.VolumetricBatchNormalization',  
  'cudnn.BatchNormalization',
}

function utils.foldBatchNorm(net)
  -- works in place!
  BNtoConv(net)
  BNtoConv(net)
  for i,v in ipairs(checklist) do
     local modules = net:findModules(v)
     if #modules > 0 then print('Couldnt fold these:', modules) end
  end
end


function utils.testSurgery(input, f, net, ...)
   local output1 = net:forward(input):clone()
   f(net,...)
   local output2 = net:forward(input):clone()
   local err = (output1 - output2):abs():max()
   return err
end

return utils
