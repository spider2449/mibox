param([switch]$Identify,[switch]$ReadBootBuffer,[switch]$AllowMissing)
$ErrorActionPreference='Stop'
if(-not ('MiboxLoader.ReadOnlyProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
namespace MiboxLoader {
  public sealed class ProbeResult {
    public bool Found; public string DevicePath; public string VidPid;
    public string IdentifyHex; public bool VendorRequestSent; public string InterfaceGuid;
    public string BootBufferAddress; public string BootBufferHex;
  }
  public static class ReadOnlyProbe {
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
      public uint Size; public Guid ClassGuid; public uint Flags; public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, Pack=1)] struct SetupPacket {
      public byte Type; public byte Request; public ushort Value; public ushort Index; public ushort Length;
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
    static extern bool WinUsb_SetPipePolicy(IntPtr handle,byte pipe,uint type,uint size,ref uint value);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ControlTransfer(IntPtr handle,SetupPacket packet,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    static void Check(bool ok,string operation) {
      if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),operation);
    }
    public static ProbeResult Run(bool identify,bool readBootBuffer,string interfaceGuid) {
      // Dedicated GUID from the checked-in, exact-device Zadig preset.
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
      if(path==null) return new ProbeResult {Found=false,VendorRequestSent=false};
      using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
        if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Open exact loader interface");
        IntPtr handle; Check(WinUsb_Initialize(file,out handle),"Initialize WinUSB");
        try {
          byte[] descriptor=new byte[18]; uint count;
          Check(WinUsb_GetDescriptor(handle,1,0,0,descriptor,18,out count),"Read standard device descriptor");
          if(count!=18 || descriptor[0]!=18 || descriptor[1]!=1 || BitConverter.ToUInt16(descriptor,8)!=0x1b8e || BitConverter.ToUInt16(descriptor,10)!=0xc003)
            throw new Exception("Descriptor does not match scoped loader; no vendor request sent");
          ProbeResult result=new ProbeResult {Found=true,DevicePath=path,VidPid="1B8E:C003",VendorRequestSent=false,InterfaceGuid=guid.ToString()};
          if(identify || readBootBuffer) {
            uint timeout=3000; Check(WinUsb_SetPipePolicy(handle,0,3,4,ref timeout),"Set bounded control timeout");
            // Reference AM_REQ_IDENTIFY_HOST: vendor IN 0x20, four-byte version/stage response.
            SetupPacket request=new SetupPacket {Type=0xc0,Request=0x20,Value=0,Index=0,Length=4};
            byte[] response=new byte[4];
            Check(WinUsb_ControlTransfer(handle,request,response,4,out count,IntPtr.Zero),"Read loader identification");
            if(count!=4) throw new Exception("Unexpected identify length");
            result.IdentifyHex=BitConverter.ToString(response); result.VendorRequestSent=true;
            if(readBootBuffer) {
              if(result.IdentifyHex!="00-08-00-10") throw new Exception("Unverified loader version; RAM read refused");
              // Saved device environment loadaddr=0x82000000. Fixed 64-byte RAM read;
              // below the reference implementation's 512-byte EP0 scratch limit.
              byte[] memory=new byte[64];
              SetupPacket read=new SetupPacket {Type=0xc0,Request=0x02,Value=0x8200,Index=0,Length=64};
              Check(WinUsb_ControlTransfer(handle,read,memory,64,out count,IntPtr.Zero),"Read saved boot buffer");
              if(count!=64) throw new Exception("Unexpected boot buffer read length");
              result.BootBufferAddress="0x82000000"; result.BootBufferHex=BitConverter.ToString(memory);
            }
          }
          return result;
        } finally {WinUsb_Free(handle);}
      }
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
    $result=[MiboxLoader.ReadOnlyProbe]::Run([bool]$Identify,[bool]$ReadBootBuffer,$guid)
    if($result.Found) {break}
}
$result | ConvertTo-Json
if(-not $result.Found -and -not $AllowMissing) {throw 'Loader interface absent: enter confirmed loader mode and install the scoped WinUSB preset first'}
