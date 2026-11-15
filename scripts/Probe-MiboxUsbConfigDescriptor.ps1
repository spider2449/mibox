# Read-only dump of the C003 loader's raw configuration descriptor.
# Standard GET_DESCRIPTOR(CONFIG) control request only; no vendor request,
# no bulk activity. Verifies the actual bulk endpoint wMaxPacketSize bytes
# that WinUSB reports as MaxPacketSize=0.
param([string]$EvidenceRoot = (Join-Path $PSScriptRoot '..\artifacts\usb-loader-protocol'))
$ErrorActionPreference='Stop'
if(-not ('MiboxLoader.ConfigDump' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
namespace MiboxLoader {
  public sealed class ConfigDumpResult {
    public bool Found; public string DevicePath; public string VidPid;
    public string ConfigHex; public int ConfigBytes; public string EndpointSummary; public string Error;
  }
  [StructLayout(LayoutKind.Sequential, Pack=1)] struct SetupPacket {
    public byte Type; public byte Request; public ushort Value; public ushort Index; public ushort Length;
  }
  public static class ConfigDump {
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
      public uint Size; public Guid ClassGuid; public uint Flags; public IntPtr Reserved;
    }
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid guid, IntPtr enumerator, IntPtr parent, uint flags);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref InterfaceData data, IntPtr detail, uint size, out uint required, IntPtr device);
    [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_Initialize(SafeFileHandle file,out IntPtr handle);
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_Free(IntPtr handle);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_GetDescriptor(IntPtr handle,byte type,byte index,ushort language,byte[] data,uint size,out uint transferred);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ControlTransfer(IntPtr handle,SetupPacket packet,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    static void Check(bool ok,string operation) {
      if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),operation);
    }
    static string Hex(byte[] data,int length) {
      var builder=new System.Text.StringBuilder(length*3);
      for(int i=0;i<length;i++) builder.Append(data[i].ToString("x2")).Append('-');
      if(length>0) builder.Length--;
      return builder.ToString();
    }
    public static ConfigDumpResult Run(string interfaceGuid) {
      var result=new ConfigDumpResult();
      Guid guid=new Guid(interfaceGuid);
      IntPtr set=SetupDiGetClassDevs(ref guid,IntPtr.Zero,IntPtr.Zero,0x12);
      if(set==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
      string path=null;
      try {
        for(uint index=0;index<64;index++) {
          InterfaceData item=new InterfaceData(); item.Size=(uint)Marshal.SizeOf(typeof(InterfaceData));
          if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,index,ref item)) {
            int error=Marshal.GetLastWin32Error();
            if(error==259) break;
            throw new Win32Exception(error,"Enumerate loader interface");
          }
          uint needed;
          SetupDiGetDeviceInterfaceDetail(set,ref item,IntPtr.Zero,0,out needed,IntPtr.Zero);
          if(needed<8 || needed>16384) throw new Exception("Invalid interface path size");
          IntPtr detail=Marshal.AllocHGlobal((int)needed);
          try {
            Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);
            Check(SetupDiGetDeviceInterfaceDetail(set,ref item,detail,needed,out needed,IntPtr.Zero),"Get loader path");
            string candidate=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
            if(Regex.IsMatch(candidate,@"vid_1b8e&pid_c003(?:#|&)",RegexOptions.IgnoreCase)) {
              if(path!=null) throw new Exception("Multiple target loaders present; refuse ambiguous selection");
              path=candidate;
            }
          } finally {Marshal.FreeHGlobal(detail);}
        }
      } finally {SetupDiDestroyDeviceInfoList(set);}
      if(path==null) { result.Found=false; return result; }
      result.Found=true; result.DevicePath=path; result.VidPid="1B8E:C003";
      using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
        if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Open exact loader interface");
        IntPtr handle; Check(WinUsb_Initialize(file,out handle),"Initialize WinUSB");
        try {
          byte[] device=new byte[18]; uint count;
          Check(WinUsb_GetDescriptor(handle,1,0,0,device,18,out count),"Read device descriptor");
          if(count!=18 || BitConverter.ToUInt16(device,8)!=0x1b8e || BitConverter.ToUInt16(device,10)!=0xc003)
            throw new Exception("Descriptor does not match scoped loader");
          // GET_DESCRIPTOR(CONFIG): type 0x80 standard IN, wValue high byte 0x02.
          // First an 9-byte read for wTotalLength, then the full configuration.
          SetupPacket head=new SetupPacket {Type=0x80,Request=6,Value=0x0200,Index=0,Length=9};
          byte[] headData=new byte[9];
          Check(WinUsb_ControlTransfer(handle,head,headData,9,out count,IntPtr.Zero),"Read configuration header");
          if(count!=9) throw new Exception("Unexpected configuration header length");
          int total=headData[2] | (headData[3]<<8);
          if(total<9 || total>255) throw new Exception("Unreasonable wTotalLength "+total);
          byte[] config=new byte[total];
          SetupPacket full=new SetupPacket {Type=0x80,Request=6,Value=0x0200,Index=0,Length=(ushort)total};
          Check(WinUsb_ControlTransfer(handle,full,config,(uint)total,out count,IntPtr.Zero),"Read full configuration descriptor");
          if(count!=(uint)total) throw new Exception("Short configuration descriptor");
          result.ConfigBytes=total; result.ConfigHex=Hex(config,total);
          var summary=new System.Text.StringBuilder();
          for(int i=0;i+7<total;i++) {
            if(config[i]==0x07 && config[i+1]==0x05) {
              byte ep=config[i+2]; int mps=config[i+4] | (config[i+5]<<8);
              summary.Append("ep0x").Append(ep.ToString("x2")).Append(",attr").Append(config[i+3])
                     .Append(",mps").Append(mps).Append(';');
            }
          }
          result.EndpointSummary=summary.ToString();
        } finally {WinUsb_Free(handle);}
      }
      return result;
    }
  }
}
'@
}
$guids=@('86C80ED9-6F95-4FB7-ABFE-744BA77DDC25')
$registryRoot='HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_1B8E&PID_C003'
if(Test-Path -LiteralPath $registryRoot) {
    foreach($instance in @(Get-ChildItem -LiteralPath $registryRoot)) {
        $parameters=Join-Path $instance.PSPath 'Device Parameters'
        foreach($text in @((Get-ItemProperty -LiteralPath $parameters -Name DeviceInterfaceGUIDs -ErrorAction SilentlyContinue).DeviceInterfaceGUIDs)) {
            $parsed=[guid]::Empty
            if([guid]::TryParse($text,[ref]$parsed)) {$guids+=$parsed.ToString()}
        }
    }
}
$result=$null
foreach($guid in @($guids | Select-Object -Unique)) {
    $result=[MiboxLoader.ConfigDump]::Run($guid)
    if($result.Found) {break}
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$directory=Join-Path $EvidenceRoot "config-dump-$stamp"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report=[ordered]@{
    timestamp_utc=(Get-Date).ToUniversalTime().ToString('o')
    method='GET_DESCRIPTOR(CONFIG) only, no vendor request, no bulk activity'
    result=$result
}
$json=$report | ConvertTo-Json -Depth 6
$encoding=New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $directory 'config-dump.json'),$json,$encoding)
if($result.ConfigHex) {[IO.File]::WriteAllText((Join-Path $directory 'config-descriptor.hex'),$result.ConfigHex,$encoding)}
$result | ConvertTo-Json -Depth 4
if(-not $result.Found) {throw 'Loader interface absent'}
