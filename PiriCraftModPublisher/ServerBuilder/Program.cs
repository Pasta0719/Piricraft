using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Mono.Cecil;
using System.Reflection;

class Program {
  static string Sha(byte[] b)=>Convert.ToHexString(SHA256.HashData(b));
  static int Main(string[] args) {
    try {
      if(args.Length<2) throw new Exception("inspect <dll>, or patch <dll> <dll-out> <manifest-in> <manifest-out> <jar> <mode> <target> <version> <repo>");
      using var assembly=AssemblyDefinition.ReadAssembly(args[1],new ReaderParameters{ReadingMode=ReadingMode.Deferred});
      var res=assembly.MainModule.Resources.OfType<EmbeddedResource>().ToArray();
      if(args[0]=="export") {
        if(args.Length!=4)throw new Exception("export <dll> <resource-name> <destination>");
        var embedded=res.SingleOrDefault(x=>x.Name==args[2])??throw new Exception("Resource absent: "+args[2]);
        File.WriteAllBytes(args[3],embedded.GetResourceData());
        Console.WriteLine("EXPORTED_RESOURCE "+args[2]+" SHA256="+Sha(embedded.GetResourceData()));
        return 0;
      }
      if(args[0]=="inspect") {
        Console.WriteLine("ASSEMBLY_VERSION "+assembly.Name.Version);
        foreach(var r in res) Console.WriteLine($"RESOURCE {r.Name} {r.GetResourceData().Length}");
        var manifest=res.First(r=>r.Name=="PiriCraft.ModsManifest.json");
        using var data=JsonDocument.Parse(manifest.GetResourceData());
        Console.WriteLine("LOCAL_MANIFEST "+data.RootElement.ToString());
        return 0;
      }
      if(args[0]!="patch" || args.Length!=11) throw new Exception("Incorrect patch arguments");
      string dllOut=args[2],manifestIn=args[3],manifestOut=args[4],jarFile=args[5],mode=args[6],target=args[7],version=args[8],repo=args[9];
      // last argument is supplied as explicit source tag
      string tag=args[10];
      if(mode!="update"&&mode!="add"&&mode!="remove")throw new Exception("mode must be update/add/remove");
      if(!System.Text.RegularExpressions.Regex.IsMatch(tag,@"^launcher-v\d+\.\d+\.\d+$"))throw new Exception("Invalid target release tag");
      var bytes=mode=="remove"?Array.Empty<byte>():File.ReadAllBytes(jarFile);
      string hash=mode=="remove"?"":Sha(bytes),newName=mode=="remove"?Path.GetFileName(target):Path.GetFileName(jarFile);
      if(!newName.EndsWith(".jar",StringComparison.OrdinalIgnoreCase)||newName.Contains('/')||newName.Contains('\\'))throw new Exception("Invalid JAR name");
      var remote=JsonNode.Parse(File.ReadAllText(manifestIn))!.AsObject();
      var remoteFiles=remote["files"]!.AsArray();
      JsonObject? current=null;
      if(mode=="update"||mode=="remove"){
        current=remoteFiles.Select(x=>x!.AsObject()).SingleOrDefault(x=>(string?)x["path"]==target);
        if(current==null)throw new Exception("Selected existing MOD not present in official manifest: "+target);
      }
      if(mode=="remove") {
        var removeName=Path.GetFileName(target);
        var resourceManifest=res.Single(x=>x.Name=="PiriCraft.ModsManifest.json");
        var localEntries=JsonNode.Parse(resourceManifest.GetResourceData())!.AsArray();
        var installed=localEntries.Select(x=>x!.AsObject()).SingleOrDefault(x=>(string?)x["fileName"]==removeName);
        if(installed==null)throw new Exception("Selected MOD missing from embedded launcher manifest: "+removeName);
        var embeddedName=(string?)installed["resource"];
        if(!string.IsNullOrWhiteSpace(embeddedName)) {
          var oldResource=assembly.MainModule.Resources.FirstOrDefault(x=>x.Name==embeddedName);
          if(oldResource==null)throw new Exception("Embedded MOD resource missing: "+embeddedName);
          assembly.MainModule.Resources.Remove(oldResource);
        }
        localEntries.Remove(installed);
        remoteFiles.Remove(current);
        assembly.MainModule.Resources.Remove(resourceManifest);
        assembly.MainModule.Resources.Add(new EmbeddedResource("PiriCraft.ModsManifest.json",
          Mono.Cecil.ManifestResourceAttributes.Private,
          System.Text.Encoding.UTF8.GetBytes(localEntries.ToJsonString(new JsonSerializerOptions{WriteIndented=true}))));
        var newVersion=new Version(version+".0");
        assembly.Name.Version=newVersion;
        foreach(var attr in assembly.CustomAttributes) {
          if(attr.AttributeType.FullName=="System.Reflection.AssemblyInformationalVersionAttribute"||
             attr.AttributeType.FullName=="System.Reflection.AssemblyFileVersionAttribute") {
            if(attr.ConstructorArguments.Count==1)
              attr.ConstructorArguments[0]=new CustomAttributeArgument(assembly.MainModule.TypeSystem.String,version);
          }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(dllOut))!);
        assembly.Write(dllOut);
        File.WriteAllText(manifestOut,remote.ToJsonString(new JsonSerializerOptions{WriteIndented=true})+"\n");
        using var verified=AssemblyDefinition.ReadAssembly(dllOut);
        var resources=verified.MainModule.Resources.OfType<EmbeddedResource>().ToArray();
        var records=JsonNode.Parse(resources.Single(x=>x.Name=="PiriCraft.ModsManifest.json").GetResourceData())!.AsArray();
        if(records.Any(x=>(string?)x?["fileName"]==removeName))throw new Exception("Removed MOD still in embedded manifest");
        if(remoteFiles.Any(x=>(string?)x?["path"]==target))throw new Exception("Removed MOD still in update manifest");
        if(!string.IsNullOrWhiteSpace(embeddedName)&&resources.Any(x=>x.Name==embeddedName))
          throw new Exception("Removed MOD remains embedded in EXE");
        Console.WriteLine("REMOVE_COMPLETE "+version+" "+target+" resources="+resources.Length);
        return 0;
      }
      var newPath="mods/"+newName;
      if(remoteFiles.Any(x=>(string?)x?["path"]==newPath && (mode=="add" || (string?)x?["path"]!=target)))
        throw new Exception("MOD filename collision: "+newName);
      var internalName="PiriCraft.Mods.upload_"+hash[..16].ToLowerInvariant()+".jar";
      var localR=res.First(x=>x.Name=="PiriCraft.ModsManifest.json");
      var local=JsonNode.Parse(localR.GetResourceData())!.AsArray();
      var oldName=mode=="update"?Path.GetFileName(target):null;
      JsonObject? localEntry=null;
      if(mode=="update") {
        localEntry=local.Select(x=>x!.AsObject()).SingleOrDefault(x=>(string?)x["fileName"]==oldName);
        if(localEntry==null)throw new Exception("Selected MOD missing from embedded launcher manifest: "+oldName);
        var previousResource=(string?)localEntry["resource"];
        if(!string.IsNullOrWhiteSpace(previousResource)){
          var oldResource=assembly.MainModule.Resources.FirstOrDefault(x=>x.Name==previousResource);
          if(oldResource!=null)assembly.MainModule.Resources.Remove(oldResource);
        }
      } else {
        localEntry=new JsonObject();
        local.Add(localEntry);
      }
      localEntry!["name"]=mode=="update"?(string?)localEntry["name"]??Path.GetFileNameWithoutExtension(newName):Path.GetFileNameWithoutExtension(newName);
      localEntry["fileName"]=newName;
      localEntry["sha256"]=hash;
      localEntry["source"]="embedded";
      localEntry["url"]=null;
      localEntry["resource"]=internalName;
      assembly.MainModule.Resources.Add(new EmbeddedResource(internalName,Mono.Cecil.ManifestResourceAttributes.Private,bytes));
      assembly.MainModule.Resources.Remove(localR);
      assembly.MainModule.Resources.Add(new EmbeddedResource("PiriCraft.ModsManifest.json",Mono.Cecil.ManifestResourceAttributes.Private,System.Text.Encoding.UTF8.GetBytes(local.ToJsonString(new JsonSerializerOptions{WriteIndented=true}))));
      if(current==null) {current=new JsonObject();remoteFiles.Add(current);}
      current["path"]=newPath;
      current["sha256"]=hash;
      current["source"]="embedded";
      current["resource"]=internalName;
      current.Remove("project");current.Remove("version");current.Remove("url");
      // Win32's old product version may remain; managed AssemblyVersion is what the updater compares.
      var vers=new Version(version+".0");
      assembly.Name.Version=vers;
      foreach(var attr in assembly.CustomAttributes){
        if(attr.AttributeType.FullName=="System.Reflection.AssemblyInformationalVersionAttribute"||attr.AttributeType.FullName=="System.Reflection.AssemblyFileVersionAttribute"){
          if(attr.ConstructorArguments.Count==1)
            attr.ConstructorArguments[0]=new CustomAttributeArgument(assembly.MainModule.TypeSystem.String,version);
        }
      }
      Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(dllOut))!);
      assembly.Write(dllOut);
      File.WriteAllText(manifestOut,remote.ToJsonString(new JsonSerializerOptions{WriteIndented=true})+"\n");
      var rebuilt=AssemblyDefinition.ReadAssembly(dllOut);
      var names=rebuilt.MainModule.Resources.OfType<EmbeddedResource>().ToArray();
      if(!names.Any(x=>x.Name==internalName && Sha(x.GetResourceData())==hash))throw new Exception("Reloaded embedded client JAR hash failed");
      var check=JsonNode.Parse(names.Single(x=>x.Name=="PiriCraft.ModsManifest.json").GetResourceData())!.AsArray();
      if(!check.Any(x=>(string?)x?["fileName"]==newName && (string?)x?["sha256"]==hash))throw new Exception("Reloaded embedded manifest invalid");
      Console.WriteLine("PATCH_COMPLETE "+version+" "+newPath+" "+hash+" resources="+names.Length);
      return 0;
    } catch(Exception e){Console.Error.WriteLine(e);return 1;}
  }
}