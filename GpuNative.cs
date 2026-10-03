using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class GpuNative {
 [DllImport("kernel32.dll")] static extern bool QueryUnbiasedInterruptTime(out ulong value);
 public static double AwakeSeconds(){ulong value;if(!QueryUnbiasedInterruptTime(out value))throw new Exception("Awake clock unavailable");return value/10000000.0;}
 [StructLayout(LayoutKind.Sequential)] struct BatteryState {public byte ac,present,charging,discharging,spare1,spare2,spare3,tag;public uint maximum,remaining;public int rate;public uint estimated,alert1,alert2;}
 [DllImport("powrprof.dll")] static extern uint CallNtPowerInformation(int level,IntPtr input,uint inputSize,out BatteryState output,uint outputSize);
 public class BatteryReading {public bool Present,Online,Charging,Discharging;public uint RemainingMWh,MaximumMWh;public double? Watts;}
 public static BatteryReading Battery(){BatteryState b;uint e=CallNtPowerInformation(5,IntPtr.Zero,0,out b,(uint)Marshal.SizeOf(typeof(BatteryState)));if(e!=0)throw new Exception("Battery API error "+e);return new BatteryReading{Present=b.present!=0,Online=b.ac!=0,Charging=b.charging!=0,Discharging=b.discharging!=0,RemainingMWh=b.remaining,MaximumMWh=b.maximum,Watts=b.discharging!=0&&b.rate< -1&&b.rate> -300000?(double?)(-(double)b.rate/1000):null};}
 [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
 static long lastIdle,lastTotal;
 public static double? CpuPercent(){long idle,kernel,user;if(!GetSystemTimes(out idle,out kernel,out user))return null;long total=kernel+user;long dt=total-lastTotal,di=idle-lastIdle;bool first=lastTotal==0;lastTotal=total;lastIdle=idle;return first||dt<=0?(double?)null:Math.Max(0,Math.Min(100,100.0*(dt-di)/dt));}
 [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint Low; public int High; public override string ToString(){return ((uint)High).ToString("x8")+":"+Low.ToString("x8");} }
 [StructLayout(LayoutKind.Sequential)] struct Source { public Luid adapter; public uint id, mode, status; }
 [StructLayout(LayoutKind.Sequential)] struct Rational { public uint n,d; }
 [StructLayout(LayoutKind.Sequential)] struct Target { public Luid adapter; public uint id,mode,tech,rotation,scaling; public Rational refresh; public uint scan; public int available; public uint status; }
 [StructLayout(LayoutKind.Sequential)] struct Path { public Source source; public Target target; public uint flags; }
 [StructLayout(LayoutKind.Explicit, Size=64)] struct Mode { [FieldOffset(0)] public uint type; }
 [StructLayout(LayoutKind.Sequential)] struct Header { public uint type,size; public Luid adapter; public uint id; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct TargetName { public Header h; public uint flags,tech; public ushort manufacturer,product; public uint connector; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)] public string name; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string device; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct AdapterName { public Header h; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string device; }
 [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
 [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags,ref uint count,[Out] Path[] paths,ref uint modes,[Out] Mode[] values,IntPtr topology);
 [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetTarget(ref TargetName name);
 [DllImport("user32.dll",EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetAdapter(ref AdapterName name);
 public class DisplayPath { public string Key,Adapter,AdapterLuid,Monitor,MonitorPath,Technology; public bool Active,Available,Internal,Nvidia; public uint TargetId; }
 public static DisplayPath[] Displays(bool all) {
  uint flag=all?1u:2u;
  for(int retry=0;retry<4;retry++) {
   uint np,nm; int e=GetDisplayConfigBufferSizes(flag,out np,out nm); if(e!=0)throw new System.ComponentModel.Win32Exception(e);
   var paths=new Path[np]; var modes=new Mode[nm]; e=QueryDisplayConfig(flag,ref np,paths,ref nm,modes,IntPtr.Zero);
   if(e==122)continue; if(e!=0)throw new System.ComponentModel.Win32Exception(e);
   var result=new List<DisplayPath>();
   for(int i=0;i<np;i++) {
    var p=paths[i]; var a=new AdapterName(); a.h.type=4;a.h.size=(uint)Marshal.SizeOf(a);a.h.adapter=p.target.adapter;
    int ae=GetAdapter(ref a); if(ae!=0)throw new System.ComponentModel.Win32Exception(ae);
    var n=new TargetName(); n.h.type=2;n.h.size=(uint)Marshal.SizeOf(n);n.h.adapter=p.target.adapter;n.h.id=p.target.id;
    int ne=GetTarget(ref n); if(ne!=0 && (p.flags&1)!=0)throw new System.ComponentModel.Win32Exception(ne);
    uint t=ne==0?n.tech:p.target.tech;
    string tech=t==5?"HDMI":t==10?"DisplayPort":t==11?"Embedded DisplayPort":t==6?"LVDS":t==0x80000000?"Internal":t==16?"Indirect wired":t==15?"Miracast":t.ToString();
    result.Add(new DisplayPath {Key=p.target.adapter+":"+p.target.id,Adapter=a.device,AdapterLuid=p.target.adapter.ToString(),Monitor=n.name,MonitorPath=n.device,Technology=tech,Active=(p.flags&1)!=0,Available=p.target.available!=0,Internal=t==11||t==6||t==0x80000000,Nvidia=(a.device??"").IndexOf("VEN_10DE",StringComparison.OrdinalIgnoreCase)>=0,TargetId=p.target.id});
   } return result.ToArray();
  } throw new Exception("Display topology kept changing");
 }
 [StructLayout(LayoutKind.Sequential)] struct DevInfo {public uint cbSize;public Guid classGuid;public uint devInst;public IntPtr reserved;}
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid guid,string enumerator,IntPtr parent,uint flags);
 [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiEnumDeviceInfo(IntPtr set,uint index,ref DevInfo info);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInstanceId(IntPtr set,ref DevInfo info,StringBuilder id,uint size,out uint required);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set,ref DevInfo info,uint property,out uint type,byte[] data,uint size,out uint required);
 [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
 [DllImport("cfgmgr32.dll")] static extern uint CM_Get_DevNode_Status(out uint status,out uint problem,uint devInst,uint flags);
 public class DeviceState {public string Id,Power;public uint Problem;public bool Present;}
 public static DeviceState ReadPower(string id) {
  var g=new Guid("4d36e968-e325-11ce-bfc1-08002be10318"); var h=SetupDiGetClassDevs(ref g,null,IntPtr.Zero,2);
  if(h==new IntPtr(-1))throw new System.ComponentModel.Win32Exception();
  try {for(uint i=0;;i++) {var d=new DevInfo();d.cbSize=(uint)Marshal.SizeOf(d);if(!SetupDiEnumDeviceInfo(h,i,ref d))break;
   var name=new StringBuilder(512);uint needed;if(!SetupDiGetDeviceInstanceId(h,ref d,name,512,out needed))continue;
   if(!String.Equals(id,name.ToString(),StringComparison.OrdinalIgnoreCase))continue;
   uint status,problem;if(CM_Get_DevNode_Status(out status,out problem,d.devInst,0)!=0)throw new Exception("Cannot read device status");
   var bytes=new byte[56];uint type;string power="Unknown";
   if(SetupDiGetDeviceRegistryProperty(h,ref d,30,out type,bytes,56,out needed) && needed>=8){uint v=BitConverter.ToUInt32(bytes,4);if(v>=1&&v<=4)power="D"+(v-1);}
   return new DeviceState{Id=id,Power=power,Problem=problem,Present=true};
  }return new DeviceState{Id=id,Power="Unknown",Present=false};}finally{SetupDiDestroyDeviceInfoList(h);}
 }
 public sealed class WatchWindow:NativeWindow,IDisposable {
  public bool DisplayChanged,Resumed,Suspended;
  public WatchWindow(){var cp=new CreateParams();cp.Caption="GPU Manager events";CreateHandle(cp);}
  protected override void WndProc(ref Message m){if(m.Msg==0x7e||m.Msg==0x219)DisplayChanged=true;if(m.Msg==0x218){if(m.WParam.ToInt32()==7||m.WParam.ToInt32()==18)Resumed=true;if(m.WParam.ToInt32()==4)Suspended=true;}base.WndProc(ref m);}
  public void Dispose(){DestroyHandle();}
 }
}
