import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import jdk.internal.org.objectweb.asm.*;

public class TestPatchCheck {
  static class Loader extends ClassLoader {Class<?> load(byte[] b){return defineClass(null,b,0,b.length);}}
  // Execute the real initializer without requiring a running Paper server.
  static Class<?> isolated(byte[] bytes){
    var writer=new ClassWriter(0);
    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM8,writer){
      public void visit(int v,int a,String n,String s,String parent,String[] interfaces){super.visit(v,a,n,s,"java/lang/Object",null);}
      public FieldVisitor visitField(int a,String n,String d,String s,Object v){return (a&Opcodes.ACC_STATIC)!=0?super.visitField(a,n,d,s,v):null;}
      public MethodVisitor visitMethod(int a,String n,String d,String s,String[] e){return n.equals("<clinit>")?super.visitMethod(a,n,d,s,e):null;}
    },0);
    return new Loader().load(writer.toByteArray());
  }
  static Object field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f.get(null);}
  // Regression: files has 5 MOD hashes, but launcher/checkServer have a 6th SHA.
  static void verifyHashScope(){
    var expected=List.of("A".repeat(64),"B".repeat(64),"C".repeat(64),"D".repeat(64),"E".repeat(64));
    String decoy="F".repeat(64);
    var json=new StringBuilder("{\"launcher\":{\"sha256\":\""+decoy+"\"},\"files\":[");
    for(int i=0;i<expected.size();i++){
      if(i>0)json.append(',');
      json.append("{\"path\":\"mods/test-").append(i).append(".jar\",\"sha256\":\"")
          .append(expected.get(i)).append("\"}");
    }
    json.append("],\"checkServer\":{\"sha256\":\"").append(decoy).append("\"}}");
    if(!PatchCheck.extractModHashes(json.toString()).equals(expected))
      throw new AssertionError("checkServer/launcher SHA contaminated MOD list");
  }
  public static void main(String[] args)throws Exception{
    verifyHashScope();
    byte[] source;
    try(var zip=new ZipFile(args[0])){source=zip.getInputStream(zip.getEntry(PatchCheck.TARGET)).readAllBytes();}
    var original=isolated(source);
    var hashes=List.of("A".repeat(64),"B".repeat(64));
    var patched=PatchCheck.rewrite(source,hashes);
    var result=isolated(patched);
    if(!field(result,"ALLOWED_HASHES").equals(Set.copyOf(hashes)))throw new AssertionError("hashes");
    var players=(Map<?,?>)field(result,"ALWAYS_ALLOWED_PLAYERS");
    if(players==null||players.isEmpty()||!players.equals(field(original,"ALWAYS_ALLOWED_PLAYERS")))throw new AssertionError("players");
    if(players.get(UUID.fromString("a227f3fa-b52d-4bfd-888e-46d15d583d78"))==null)throw new AssertionError("NG player lookup");
    var again=isolated(PatchCheck.rewrite(patched,List.of("C".repeat(64))));
    if(!field(again,"ALLOWED_HASHES").equals(Set.of("C".repeat(64)))||!field(again,"ALWAYS_ALLOWED_PLAYERS").equals(players))throw new AssertionError("repeat");
    if(args.length>1 && args[1].endsWith(".json")){
      var expected=new HashSet<String>(PatchCheck.extractModHashes(Files.readString(Path.of(args[1]))));
      if(!field(original,"ALLOWED_HASHES").equals(expected))throw new AssertionError("published manifest mismatch");
      System.out.println("MANIFEST_MATCH count="+expected.size());
    } else if(args.length>1){
      try(var zip=new ZipFile(args[1])){
        var broken=zip.getInputStream(zip.getEntry(PatchCheck.TARGET)).readAllBytes();
        try{PatchCheck.rewrite(broken,hashes);throw new AssertionError("broken baseline accepted");}catch(IllegalStateException expected){}
      }
    }
    System.out.println("PASS: real initializer, exact hashes, preserved players, NG lookup, repeated update, broken baseline rejection");
  }
}
