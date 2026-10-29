import solc from 'solc'; import fs from 'fs';
const src = f => ({ content: fs.readFileSync('src/'+f,'utf8') });
const input = { language:'Solidity', sources:{ 'KX9Shield.sol':src('KX9Shield.sol'), 'KX9ShieldFactory.sol':src('KX9ShieldFactory.sol'), 'Mocks.sol':{content:fs.readFileSync('test/Mocks.sol','utf8')} },
  settings:{ optimizer:{enabled:true,runs:200}, viaIR:true, evmVersion:'shanghai', outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.methodIdentifiers']}} } };
const out = JSON.parse(solc.compile(JSON.stringify(input)));
let fail=false;(out.errors||[]).forEach(e=>{console.log(e.severity, e.formattedMessage.split('\n').slice(0,3).join(' | ')); if(e.severity==='error') fail=true});
if(fail) process.exit(1);
fs.mkdirSync('out',{recursive:true});
for (const [file,cs] of Object.entries(out.contracts)) for (const [name,c] of Object.entries(cs)) {
  fs.writeFileSync(`out/${name}.json`, JSON.stringify({contractName:name, abi:c.abi, bytecode:'0x'+c.evm.bytecode.object, methodIdentifiers:c.evm.methodIdentifiers},null,2));
  console.log(name, (c.evm.bytecode.object.length/2)+' bytes');
}
