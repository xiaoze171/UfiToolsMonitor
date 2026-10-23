import struct

class FDT:
    def __init__(self, data):
        self.d = data
        magic, totalsize, off_struct, off_strings = struct.unpack('>4I', data[:16])
        self.total = totalsize
        ver, last_comp, boot_cpu, size_strings, size_struct = struct.unpack('>5I', data[20:40])
        self.off_struct, self.off_strings = off_struct, off_strings
        self.strs = data[off_strings:off_strings+size_strings]
        self.struct_blk = data[off_struct:off_struct+size_struct]
        self.tree = self._parse()

    def s(self, off):
        e = self.strs.index(b'\0', off)
        return self.strs[off:e].decode('utf-8','replace')

    def _parse(self):
        root = {'name':'', 'props':{}, 'children':[]}
        stack=[root]; i=0; blk=self.struct_blk
        while i < len(blk):
            tok = struct.unpack('>I', blk[i:i+4])[0]; i+=4
            if tok==1:
                e=blk.index(b'\0', i); name=blk[i:e].decode('utf-8','replace'); i=(e+4)&~3
                node={'name':name,'props':{},'children':[]}
                stack[-1]['children'].append(node); stack.append(node)
            elif tok==2:
                stack.pop()
            elif tok==3:
                ln, nameoff = struct.unpack('>II', blk[i:i+8]); i+=8
                val = blk[i:i+ln]; i=(i+ln+3)&~3
                stack[-1]['props'][self.s(nameoff)] = val
            elif tok==4:
                pass
            elif tok==9:
                break
        return root

def walk(node, path=''):
    p = path+'/'+node['name'] if node['name'] else path
    yield p, node
    for c in node['children']:
        yield from walk(c, p)

def u32s(b):
    return list(struct.unpack('>%dI'%(len(b)//4), b[:len(b)//4*4]))
