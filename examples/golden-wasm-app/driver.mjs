// FLNT ABI v1. Pure decoding is separately testable without a DOM.
const tags = new Map([[1,"div"],[2,"span"],[3,"button"],[4,"input"],[5,"canvas"],[6,"p"]]);
const decoder = new TextDecoder("utf-8", {fatal:true});
const require = (condition, message) => { if (!condition) throw new Error(message); };
export function initialState(epoch = 1) {
    require(Number.isInteger(epoch)&&epoch>0&&epoch<=0xffffffff,"invalid session epoch");
    return {epoch,sequence:null,nodes:new Map([[0,{generation:1,parent:null,children:new Set(),tag:"span"}]]), generations:new Map([[0,1]])};
}
export function decodeBatch(memory, pointer, length, state = initialState(), capabilities = {}) {
    const buffer = memory.buffer;
    require(buffer instanceof ArrayBuffer,"shared memory is not supported by ABI v1");
    require(Number.isInteger(pointer)&&Number.isInteger(length)&&pointer>=0&&length>=32&&length<=1048576, "invalid batch range");
    require(length<=buffer.byteLength&&pointer<=buffer.byteLength-length,"out of memory range");
    const d = new DataView(buffer,pointer,length);
    require(d.getUint32(0,true)===0x544e4c46 && d.getUint16(4,true)===1,"unsupported ABI");
    require(d.getUint16(6,true)===0&&d.getUint32(8,true)===length&&d.getUint32(24,true)===0&&d.getUint32(28,true)===0,"invalid header");
    const sequence=d.getUint32(16,true),epoch=d.getUint32(20,true);
    require(epoch>0&&epoch===state.epoch,"session epoch mismatch");
    if(state.sequence!==null) {
        const advance=(sequence-state.sequence)>>>0;
        require(advance>0&&advance<0x80000000,"replayed or out-of-order batch");
    }
    const count=d.getUint32(12,true); require(count<=4096,"command limit");
    const nodes=new Map([...state.nodes].map(([k,v])=>[k,{...v,children:new Set(v.children)}]));
    const generations=new Map(state.generations); const operations=[];
    const node=(id,gen)=>{const n=nodes.get(id);require(n&&n.generation===gen,"stale node");return n;};
    function mounted(id) {
        let steps=0;
        while(id!==null) {
            if(id===0)return true;
            require(++steps<=65,"node depth");id=nodes.get(id).parent;
        }
        return false;
    }
    function retire(id,removed) {
        const n=nodes.get(id);require(n,"unknown removed node");
        for (const child of [...n.children]) retire(child,removed);
        if(n.parent!==null) nodes.get(n.parent)?.children.delete(id);
        nodes.delete(id);generations.set(id,n.generation===0xffffffff?-1:n.generation+1);removed.push(id);
    }
    function text(offset,size,end) {
        require(size<=65536&&offset<=end&&size<=end-offset,"invalid text length");
        return decoder.decode(new Uint8Array(buffer,pointer+offset,size));
    }
    let p=32;
    for(let c=0;c<count;c++) {
        require(p<=length-16,"truncated record");
        const opcode=d.getUint16(p,true),flags=d.getUint16(p+2,true),bytes=d.getUint32(p+4,true);
        const id=d.getUint32(p+8,true),generation=d.getUint32(p+12,true),q=p+16;
        require(flags===0&&bytes>=16&&bytes%8===0&&bytes<=length-p,"invalid record size");
        require(id<65536&&generation>0,"invalid handle");
        const end=p+bytes; let used=q;const op={opcode,id,generation,removed:[]};
        if(opcode===1) {
            require(bytes===24&&d.getUint16(q+2,true)===0,"invalid create payload");
            op.tag=tags.get(d.getUint16(q,true));require(op.tag,"unknown element tag");
            require(!nodes.has(id)&&id!==0&&generation===(generations.get(id)??1),"duplicate or retired create");
            nodes.set(id,{generation,parent:null,children:new Set(),tag:op.tag,
                width:op.tag==="canvas"?300:null,height:op.tag==="canvas"?150:null});
            generations.set(id,generation);used=q+4;
        } else if(opcode===2) {
            const n=node(id,generation);require(q<=end-4,"truncated text");const size=d.getUint32(q,true);
            op.text=text(q+4,size,end);used=q+4+size;
            for(const child of [...n.children]) retire(child,op.removed);n.children.clear();
        } else if(opcode===3) {
            node(id,generation);require(q<=end-8,"truncated attribute");const a=d.getUint32(q,true),b=d.getUint32(q+4,true);
            op.name=text(q+8,a,end);op.value=text(q+8+a,b,end);used=q+8+a+b;
            require(["title","aria-label","class","value"].includes(op.name)||/^data-[a-z0-9-]+$/.test(op.name),"attribute denied");
        } else if(opcode===4) {
            const parent=node(id,generation);require(bytes===24,"invalid append payload");
            op.child=d.getUint32(q,true);op.childGeneration=d.getUint32(q+4,true);const child=node(op.child,op.childGeneration);
            require(op.child!==0&&op.child!==id,"invalid reparent");
            require(!mounted(op.child)||mounted(id),"reparent leaves mount subtree");
            let ancestor=id,steps=0;
            while(ancestor!==null) {require(ancestor!==op.child,"node cycle");require(++steps<=64,"node depth");ancestor=nodes.get(ancestor).parent;}
            const pending=[[op.child,steps]];
            while(pending.length) {
                const [descendant,depth]=pending.pop();require(depth<=64,"node depth");
                for(const nested of nodes.get(descendant).children)pending.push([nested,depth+1]);
            }
            if(child.parent!==null) nodes.get(child.parent).children.delete(op.child);
            child.parent=id;parent.children.add(op.child);used=q+8;
        } else if(opcode===5) {
            node(id,generation);require(bytes===16&&id!==0,"invalid remove payload");retire(id,op.removed);used=q;
        } else if(opcode===6) {
            const canvas=node(id,generation);
            require(canvas.tag==="canvas"&&capabilities.canvas===true,"canvas unavailable");
            require(bytes===40&&d.getUint32(q,true)===1,"invalid canvas command");
            op.x=d.getInt32(q+4,true);op.y=d.getInt32(q+8,true);op.width=d.getUint32(q+12,true);op.height=d.getUint32(q+16,true);op.rgba=d.getUint32(q+20,true);
            require(op.x>=0&&op.y>=0&&op.width<=16384&&op.height<=16384&&
                op.x<=canvas.width&&op.y<=canvas.height&&op.width<=canvas.width-op.x&&op.height<=canvas.height-op.y,"canvas bounds");used=q+24;
        } else if(opcode===7) {
            require(node(id,generation).tag==="canvas"&&capabilities.webgpu===true,"WebGPU unavailable");
            require(bytes===40&&d.getUint32(q,true)===1,"invalid GPU command");
            op.rgba=[0,1,2,3].map(i=>d.getFloat32(q+4+i*4,true));
            require(op.rgba.every(x=>Number.isFinite(x)&&x>=0&&x<=1),"invalid GPU color");used=q+20;
        } else throw new Error("unknown opcode");
        require(used<=end,"payload exceeds record");
        for(let i=used;i<end;i++) require(d.getUint8(i)===0,"nonzero padding");
        operations.push(op);p=end;
    }
    require(p===length,"trailing data or incorrect count");
    return {operations,state:{nodes,generations,epoch,sequence},sequence,epoch};
}
export function createDriver(mount,{gpuDevice=null,epoch=1}={}) {
    let state=initialState(epoch);const elements=new Map([[0,mount]]);
    const canvasSupport=typeof document!=="undefined"&&document.createElement("canvas").getContext("2d")!==null;
    function apply(memory,pointer,length) {
        for(const [id,element] of elements) {
            const registered=state.nodes.get(id);
            if(registered.tag==="canvas")require(element.width===registered.width&&element.height===registered.height,"canvas dimensions changed outside ABI");
        }
        const decoded=decodeBatch(memory,pointer,length,state,{canvas:canvasSupport,webgpu:gpuDevice!==null});
        // Validation above completes before any DOM mutation. Driver/device failures
        // are operational errors; callers stop rendering instead of retrying a half batch.
        for(const op of decoded.operations) {
            if(op.opcode===1) elements.set(op.id,document.createElement(op.tag));
            else if(op.opcode===2) elements.get(op.id).textContent=op.text;
            else if(op.opcode===3) elements.get(op.id).setAttribute(op.name,op.value);
            else if(op.opcode===4) elements.get(op.id).appendChild(elements.get(op.child));
            else if(op.opcode===5) elements.get(op.id).remove();
            else if(op.opcode===6) {
                const ctx=elements.get(op.id).getContext("2d");require(ctx,"canvas context unavailable");
                const c=op.rgba;ctx.fillStyle=`rgba(${c>>>24},${(c>>>16)&255},${(c>>>8)&255},${(c&255)/255})`;
                ctx.fillRect(op.x,op.y,op.width,op.height);
            } else if(op.opcode===7) {
                const ctx=elements.get(op.id).getContext("webgpu");require(ctx,"GPU context unavailable");
                ctx.configure({device:gpuDevice,format:navigator.gpu.getPreferredCanvasFormat(),alphaMode:"premultiplied"});
                const encoder=gpuDevice.createCommandEncoder();const [r,g,b,a]=op.rgba;
                const pass=encoder.beginRenderPass({colorAttachments:[{view:ctx.getCurrentTexture().createView(),clearValue:{r,g,b,a},loadOp:"clear",storeOp:"store"}]});
                pass.end();gpuDevice.queue.submit([encoder.finish()]);
            }
            for(const id of op.removed) elements.delete(id);
        }
        state=decoded.state;return decoded.operations.length;
    }
    return {apply};
}
