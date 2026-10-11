using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Mono.Cecil;
class Program {
  static int Main(string[] args) {
    try {
      if(args.Length<2) throw new Exception("Expected inspect <dll> or patch <dll> <output> <plan.json> <mod.jar>");
      var assembly=AssemblyDefinition.ReadAssembly(args[1],new ReaderParameters{ReadingMode=ReadingMode.Immediate});
      var res=assembly.MainModule.Resources.OfType<EmbeddedResource>().ToArray();
      Console.WriteLine("ASSEMBLY_VERSION "+assembly.Name.Version);
      foreach(var r in res) Console.WriteLine($"RESOURCE {r.Name} {r.GetResourceData().Length}");
      var manifest=res.First(r=>r.Name=="PiriCraft.ModsManifest.json");
      using(var data=JsonDocument.Parse(manifest.GetResourceData())) Console.WriteLine("LOCAL_MANIFEST "+data.RootElement.ToString());
      if(args[0]=="inspect")return 0;
      throw new Exception("Unknown command");
    } catch(Exception e) {Console.Error.WriteLine(e);return 1;}
  }
}