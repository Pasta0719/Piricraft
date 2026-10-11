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
    String manifest=Files.readString(Path.of(args[2]));
    var hashes=new ArrayList<String>();
    var match=java.util.regex.Pattern.compile("\\\"sha256\\\"\\s*:\\s*\\\"([A-Fa-f0-9]{64})\\\"").matcher(manifest);
    while(match.find()) hashes.add(match.group(1).toUpperCase(Locale.ROOT));
    if(hashes.size()<5 || hashes.size()!=new HashSet<>(hashes).size())throw new Exception("Invalid or duplicate authorized hashes");
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
  static byte[] rewrite(byte[] source,List<String> hashes){
    ClassReader reader=new ClassReader(source);
    ClassWriter writer=new ClassWriter(reader,ClassWriter.COMPUTE_MAXS | ClassWriter.COMPUTE_FRAMES);
    final boolean[] removed={false},field={false};
    reader.accept(new ClassVisitor(Opcodes.ASM8,writer){
      public FieldVisitor visitField(int access,String name,String desc,String sig,Object value){
        if(name.equals("ALLOWED_HASHES") && desc.equals("Ljava/util/Set;"))field[0]=true;
        return super.visitField(access,name,desc,sig,value);
      }
      public MethodVisitor visitMethod(int access,String name,String desc,String sig,String[] exceptions){
        if(name.equals("<clinit>") && desc.equals("()V")){removed[0]=true;return null;}
        return super.visitMethod(access,name,desc,sig,exceptions);
      }
    },0);
    if(!removed[0]||!field[0])throw new IllegalStateException("Unrecognized original Check plugin layout");
    MethodVisitor mv=writer.visitMethod(Opcodes.ACC_STATIC,"<clinit>","()V",null,null);
    mv.visitCode();
    mv.visitLdcInsn(hashes.size());
    mv.visitTypeInsn(Opcodes.ANEWARRAY,"java/lang/Object");
    for(int i=0;i<hashes.size();i++){
      mv.visitInsn(Opcodes.DUP);
      mv.visitLdcInsn(i);
      mv.visitLdcInsn(hashes.get(i));
      mv.visitInsn(Opcodes.AASTORE);
    }
    mv.visitMethodInsn(Opcodes.INVOKESTATIC,"java/util/Set","of","([Ljava/lang/Object;)Ljava/util/Set;",true);
    mv.visitFieldInsn(Opcodes.PUTSTATIC,"jp/piricraft/check/PiricraftCheckPlugin","ALLOWED_HASHES","Ljava/util/Set;");
    mv.visitInsn(Opcodes.RETURN);
    mv.visitMaxs(0,0);mv.visitEnd();
    return writer.toByteArray();
  }
}