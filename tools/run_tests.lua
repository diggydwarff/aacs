-- Run from the AACS package root: texlua tools/run_tests.lua
-- Or use Lua 5.2/5.3 with bit32: lua tools/run_tests.lua
package.path='./?.lua;'..package.path
local json=dofile('tools/test_json.lua')
textutils={serializeJSON=json.encode,unserializeJSON=json.decode,serialize=json.encode,pagedPrint=print}
fs={};peripheral={};redstone={}
os.epoch=function() return os.time()*1000 end
local count=require('aacs.tests.selftest').run()
print('Standalone Lua checks completed: '..count)
