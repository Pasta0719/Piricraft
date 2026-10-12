import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.*;
import jdk.internal.org.objectweb.asm.*;

public final class PatchCheck {
  static final String TARGET="jp/piricraft/check/PiricraftCheckPlugin.class";
  public static void main(String[] args) throws Exception {
    if(args.length!=3) throw new Exception("Usage PatchCheck original.jar updated.jar remote-manifest.json");
    // Parse official SHA-256 values from JSON without depending on JSON libraries.
    var hashes=extractModHashes(Files.readString(Path.of(args[2])));
    try(ZipFile original=new ZipFile(args[0]); ZipOutputStream output=new ZipOutputStream(Files.newOutputStream(Path.of(args[1])))){
      boolean found=false;
      Enumeration<? extends ZipEntry> e=original.entries();
      while(e.hasMoreElements()){
        ZipEntry it=e.nextElement();
        byte[] raw=original.getInputStream(it).readAllBytes();
        if(it.getName().equals(TARGET)){raw=rewrite(raw,hashes);found=true;}
        ZipEntry next=new ZipEntry(it.getName());
        next.setTime(it.getTime());
        output.putNextEntry(next);output.write(raw);output.closeEntry();
      }
      if(!found)throw new Exception("Original Check server class not found");
    }
    try(ZipFile check=new ZipFile(args[1])){
      var cl=check.getEntry(TARGET);
      if(cl==null || check.getInputStream(cl).readAllBytes().length<500)throw new Exception("Built Check JAR invalid");
    }
    System.out.println("CHECK_SERVER_MOD_ALLOWLIST_UPDATED count="+hashes.size());
  }
  // Select only the files array; a checkServer.sha256 follows it in release manifests.
  // Taking every sha256 after the "files" key incorrectly adds the Check JAR itself.
  static List<String> extractModHashes(String manifest){
    var field=java.util.regex.Pattern.compile("\"files\"\\s*:\\s*\\[").matcher(manifest);
    if(!field.find())throw new IllegalArgumentException("Missing files array");
    int start=field.end()-1,depth=0,end=-1;
    boolean quoted=false,escaped=false;
    for(int i=start;i<manifest.length();i++){
      char c=manifest.charAt(i);
      if(quoted){
        if(escaped)escaped=false;
        else if(c=='\\')escaped=true;
        else if(c=='"')quoted=false;
      }else if(c=='"')quoted=true;
      else if(c=='[')depth++;
      else if(c==']' && --depth==0){end=i;break;}
    }
    if(end<0)throw new IllegalArgumentException("Unclosed files array");
    String files=manifest.substring(start,end+1);
    var hashes=new ArrayList<String>();
    var match=java.util.regex.Pattern.compile("\"sha256\"\\s*:\\s*\"([A-Fa-f0-9]{64})\"").matcher(files);
    while(match.find())hashes.add(match.group(1).toUpperCase(Locale.ROOT));
    long modPaths=java.util.regex.Pattern.compile("\"path\"\\s*:\\s*\"mods/[^\"]+\\.jar\"").matcher(files).results().count();
    if(hashes.size()<5 || hashes.size()!=modPaths || hashes.size()!=new HashSet<>(hashes).size())
      throw new IllegalArgumentException("Invalid, missing, or duplicate authorized MOD hashes");
    return hashes;
  }
  static byte[] rewrite(byte[] source,List<String> hashes){
    ClassReader reader=new ClassReader(source);
    ClassWriter writer=new ClassWriter(reader,ClassWriter.COMPUTE_MAXS | ClassWriter.COMPUTE_FRAMES);
    final boolean[] initialized={false},field={false},players={false};
    reader.accept(new ClassVisitor(Opcodes.ASM8,writer){
      public FieldVisitor visitField(int access,String name,String desc,String sig,Object value){
        if(name.equals("ALLOWED_HASHES") && desc.equals("Ljava/util/Set;"))field[0]=true;
        return super.visitField(access,name,desc,sig,value);
      }
      public MethodVisitor visitMethod(int access,String name,String desc,String sig,String[] exceptions){
        MethodVisitor original=super.visitMethod(access,name,desc,sig,exceptions);
        if(!name.equals("<clinit>") || !desc.equals("()V"))return original;
        return new MethodVisitor(Opcodes.ASM8,original){
          public void visitFieldInsn(int opcode,String owner,String name,String descriptor){
            if(opcode==Opcodes.PUTSTATIC && owner.equals("jp/piricraft/check/PiricraftCheckPlugin")){
              if(name.equals("ALWAYS_ALLOWED_PLAYERS"))players[0]=true;
              if(name.equals("ALLOWED_HASHES") && descriptor.equals("Ljava/util/Set;")){
                initialized[0]=true;
                super.visitInsn(Opcodes.POP);
                emitHashes(this,hashes);
              }
            }
            super.visitFieldInsn(opcode,owner,name,descriptor);
          }
        };
      }
    },0);
    if(!initialized[0]||!field[0]||!players[0])throw new IllegalStateException("Check baseline has missing static initialization; use a repaired Check JAR before publishing");
    return writer.toByteArray();
  }
  static void emitHashes(MethodVisitor mv,List<String> hashes){
    mv.visitLdcInsn(hashes.size());
    mv.visitTypeInsn(Opcodes.ANEWARRAY,"java/lang/Object");
    for(int i=0;i<hashes.size();i++){
      mv.visitInsn(Opcodes.DUP);
      mv.visitLdcInsn(i);
      mv.visitLdcInsn(hashes.get(i));
      mv.visitInsn(Opcodes.AASTORE);
    }
    mv.visitMethodInsn(Opcodes.INVOKESTATIC,"java/util/Set","of","([Ljava/lang/Object;)Ljava/util/Set;",true);
  }
}
