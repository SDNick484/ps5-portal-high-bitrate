import base64, unittest
from unittest.mock import patch
from scapy.all import Ether,IP,UDP,Raw
import portal_active_probe as p
import portal_capture as n

def varint(x):
 b=bytearray()
 while x>127:b.append((x&127)|128);x>>=7
 return bytes(b)+bytes([x])
def field(k,v):
 return varint(k*8)+varint(v) if isinstance(v,int) else varint(k*8+2)+varint(len(v))+v
def fixture():
 plain=b' '*334+b'25000'+b' '*(1721-339)
 stream=bytes((i*19+31)%256 for i in range(len(plain)))
 cipher=bytes(a^b for a,b in zip(plain,stream))
 msg=field(1,0)+field(2,field(1,20)+field(2,b'synthetic')+field(3,base64.b64encode(cipher))+field(4,b''))
 data=(7).to_bytes(4,'big')+b'\0'*4+b'\0'+msg[:1200]
 packet=b'\0tagg'+b'\0'*8+b'\0\0'+(len(data)+4).to_bytes(2,'big')+data
 return packet,plain,stream,packet.index(base64.b64encode(cipher)[:20])
class MutationTests(unittest.TestCase):
 def test_profiles(self):
  for delta,expected in [(b'\x04',b'65000'),(bytes.fromhex('03501b0005'),b'1e+05')]:
   data,plain,stream,pos=fixture()
   with patch.object(p,'PATCH_DELTA',delta):
    changed,yes=p.mutate(data)
    self.assertTrue(yes);self.assertEqual(len(changed),len(data))
    cipher=base64.b64decode(changed[pos:pos+800])
    decoded=bytes(a^b for a,b in zip(cipher,stream))
    self.assertEqual(decoded,plain[:334]+expected+plain[339:len(decoded)])
    self.assertEqual(p.mutate(changed),(data,True))
 def test_invalid_packets(self):
  data,*_=fixture()
  for bad in [b'',data[:30],data[:5]+b'abcd'+data[9:],data.replace(b'\xf8\x11',b'\xf7\x11',1)]:
   self.assertNotEqual(bad,data);self.assertEqual(p.mutate(bad),(bad,False))
 def test_checksum_and_pair(self):
  data,*_=fixture();s={'own_mac':'02:00:00:00:00:01','ps5_mac':'02:00:00:00:00:02','portal_mac':'02:00:00:00:00:03'}
  frame=bytes(Ether(src=s['portal_mac'],dst=s['own_mac'])/IP(src=n.PORTAL,dst=n.PS5)/UDP(sport=50000,dport=9296)/Raw(data))
  out,_,direction,changed=p.transform(frame,s,True)
  self.assertTrue(changed);self.assertEqual(direction,'out')
  packet=Ether(out);ip=bytes(packet[IP]);udp=bytes(packet[UDP])
  self.assertEqual(p.checksum(ip[12:20]+b'\0\x11'+len(udp).to_bytes(2,'big')+udp),0)
  baseline,*_=p.transform(frame,s,False);self.assertEqual(baseline[12:],frame[12:])
  other=bytes(Ether(dst=s['own_mac'])/IP(src='192.0.2.99',dst=n.PS5)/UDP()/Raw(data))
  self.assertIsNone(p.transform(other,s,True))
class ConfirmationTests(unittest.TestCase):
 def test_stale_reports(self):
  c=p.TargetConfirmation()
  for _ in range(4):c.observe({'type':'CONNECTIONQUALITY','target_bitrate_raw':97087000})
  self.assertFalse(c.ready)
 def test_sequence(self):
  c=p.TargetConfirmation();c.modified();c.observe({'type':'BANG','key_accepted':1,'version_accepted':1});c.observe({'type':'STREAMINFO'})
  for _ in range(2):c.observe({'type':'CONNECTIONQUALITY','target_bitrate_raw':97087000})
  self.assertFalse(c.ready)
  c.observe({'type':'CONNECTIONQUALITY','target_bitrate_raw':1000});self.assertEqual(c.samples,0)
  for _ in range(3):c.observe({'type':'CONNECTIONQUALITY','target_bitrate_raw':97087000})
  self.assertTrue(c.ready);c.observe({'type':'DISCONNECT'});self.assertFalse(c.ready)
class NetworkTests(unittest.TestCase):
 def test_bad_config(self):
  for c in [{},{'interface':'en0;id','ps5_ip':'192.0.2.10','portal_ip':'192.0.2.20'},{'interface':'en0','ps5_ip':'127.0.0.1','portal_ip':'192.0.2.20'},{'interface':'en0','ps5_ip':'192.0.2.20','portal_ip':'192.0.2.20'}]:
   with self.assertRaises(ValueError):n.validate_config(c)
 def test_restore_sysctls_after_arp_failure(self):
  state={'config':{},'sysctl':dict(zip(n.KEYS,['0','1']))}
  with patch.object(n,'configure'),patch.object(n.conf,'L2socket',side_effect=OSError('synthetic')),patch.object(n,'syswrite') as write:
   self.assertEqual(len(n.restore(state)),1);self.assertEqual(write.call_count,2)
 def test_restore_peer_addresses(self):
  s={'own_mac':'02:00:00:00:00:01','ps5_mac':'02:00:00:00:00:02','portal_mac':'02:00:00:00:00:03'}
  a,b=n.frames(s,True)
  self.assertEqual(a[n.ARP].hwsrc,s['portal_mac']);self.assertEqual(b[n.ARP].hwsrc,s['ps5_mac'])
  self.assertEqual(a[n.ARP].pdst,n.PS5);self.assertEqual(b[n.ARP].pdst,n.PORTAL)
