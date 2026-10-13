import java.nio.file.*;
import jdk.internal.org.objectweb.asm.*;
import jdk.internal.org.objectweb.asm.tree.*;

/** Repairs postprocessing state leakage into Minecraft's subsequent first-person item pass. */
public class AbyssRenderStatePatcher implements Opcodes {
  private static final String GL11="org/lwjgl/opengl/GL11", GL13="org/lwjgl/opengl/GL13", GL20="org/lwjgl/opengl/GL20", GL30="org/lwjgl/opengl/GL30";
  private static final String RENDER="com/mojang/blaze3d/systems/RenderSystem";
  private static final String CONTEXT="Lnet/fabricmc/fabric/api/client/rendering/v1/WorldRenderContext;";
  private static final int GL_TEXTURE0=33984, GL_TEXTURE1=33985, GL_ACTIVE_TEXTURE=34016, GL_TEXTURE_BINDING_2D=32873;
  private static final int GL_CURRENT_PROGRAM=35725, GL_VERTEX_ARRAY_BINDING=34229, GL_READ_FRAMEBUFFER_BINDING=36010;
  private static final int GL_DRAW_FRAMEBUFFER_BINDING=36006, GL_READ_FRAMEBUFFER=36008, GL_DRAW_FRAMEBUFFER=36009;
  private static final int GL_DEPTH_TEST=2929, GL_BLEND=3042, GL_DEPTH_WRITEMASK=2930;
  static void integer(MethodVisitor m,int v){m.visitLdcInsn(v);}
  static void getInt(MethodVisitor m,int p,int i){integer(m,p);m.visitMethodInsn(INVOKESTATIC,GL11,"glGetInteger","(I)I",false);m.visitVarInsn(ISTORE,i);}
  static void enabled(MethodVisitor m,int p,int i){integer(m,p);m.visitMethodInsn(INVOKESTATIC,GL11,"glIsEnabled","(I)Z",false);m.visitVarInsn(ISTORE,i);}
  static void active(MethodVisitor m,int unit){integer(m,unit);m.visitMethodInsn(INVOKESTATIC,GL13,"glActiveTexture","(I)V",false);}
  static void restore(MethodVisitor m) {
    m.visitVarInsn(ILOAD,5);m.visitMethodInsn(INVOKESTATIC,GL20,"glUseProgram","(I)V",false);
    m.visitVarInsn(ILOAD,6);m.visitMethodInsn(INVOKESTATIC,GL30,"glBindVertexArray","(I)V",false);
    active(m,GL_TEXTURE0);integer(m,3553);m.visitVarInsn(ILOAD,8);m.visitMethodInsn(INVOKESTATIC,GL11,"glBindTexture","(II)V",false);
    active(m,GL_TEXTURE1);integer(m,3553);m.visitVarInsn(ILOAD,9);m.visitMethodInsn(INVOKESTATIC,GL11,"glBindTexture","(II)V",false);
    m.visitVarInsn(ILOAD,7);m.visitMethodInsn(INVOKESTATIC,GL13,"glActiveTexture","(I)V",false);
    integer(m,GL_READ_FRAMEBUFFER);m.visitVarInsn(ILOAD,3);m.visitMethodInsn(INVOKESTATIC,GL30,"glBindFramebuffer","(II)V",false);
    integer(m,GL_DRAW_FRAMEBUFFER);m.visitVarInsn(ILOAD,4);m.visitMethodInsn(INVOKESTATIC,GL30,"glBindFramebuffer","(II)V",false);
    Label a=new Label(),b=new Label();m.visitVarInsn(ILOAD,10);m.visitJumpInsn(IFEQ,a);
    integer(m,GL_DEPTH_TEST);m.visitMethodInsn(INVOKESTATIC,GL11,"glEnable","(I)V",false);m.visitJumpInsn(GOTO,b);
    m.visitLabel(a);integer(m,GL_DEPTH_TEST);m.visitMethodInsn(INVOKESTATIC,GL11,"glDisable","(I)V",false);m.visitLabel(b);
    Label c=new Label(),d=new Label();m.visitVarInsn(ILOAD,11);m.visitJumpInsn(IFEQ,c);
    integer(m,GL_BLEND);m.visitMethodInsn(INVOKESTATIC,GL11,"glEnable","(I)V",false);m.visitJumpInsn(GOTO,d);
    m.visitLabel(c);integer(m,GL_BLEND);m.visitMethodInsn(INVOKESTATIC,GL11,"glDisable","(I)V",false);m.visitLabel(d);
    m.visitVarInsn(ILOAD,12);m.visitMethodInsn(INVOKESTATIC,GL11,"glDepthMask","(Z)V",false);
    for(int i=0;i<4;i++){m.visitVarInsn(ALOAD,14);integer(m,i);m.visitInsn(IALOAD);}
    m.visitMethodInsn(INVOKESTATIC,GL11,"glViewport","(IIII)V",false);
  }
  public static byte[] patch(byte[] input){
    ClassNode node=new ClassNode();new ClassReader(input).accept(node,0);
    String desc="("+CONTEXT+")V";MethodNode original=null;
    for(MethodNode m:node.methods)if(m.name.equals("render")&&m.desc.equals(desc))original=m;
    if(original==null)throw new IllegalStateException("render() missing");
    original.name="renderOriginal";original.access=ACC_PRIVATE;
    int switched=0;
    for(MethodNode m:node.methods)if(m.name.equals("draw"))for(AbstractInsnNode ins=m.instructions.getFirst();ins!=null;){
      AbstractInsnNode next=ins.getNext();
      if(ins instanceof MethodInsnNode mi&&mi.owner.equals(RENDER)){
        String name=mi.name;
        if(name.equals("disableDepthTest")||name.equals("enableDepthTest")||name.equals("disableBlend")){
          m.instructions.insertBefore(mi,new LdcInsnNode(name.equals("disableBlend")?GL_BLEND:GL_DEPTH_TEST));
          mi.owner=GL11;mi.name=name.equals("enableDepthTest")?"glEnable":"glDisable";mi.desc="(I)V";mi.itf=false;switched++;
        }else if(name.equals("depthMask")){mi.owner=GL11;mi.name="glDepthMask";mi.itf=false;switched++;}
      }
      ins=next;
    }
    if(switched!=5)throw new IllegalStateException("Unexpected RenderSystem mutations: "+switched);
    MethodNode m=new MethodNode(ASM8,0,"render",desc,null,null);node.methods.add(m);m.visitCode();
    getInt(m,GL_READ_FRAMEBUFFER_BINDING,3);getInt(m,GL_DRAW_FRAMEBUFFER_BINDING,4);
    getInt(m,GL_CURRENT_PROGRAM,5);getInt(m,GL_VERTEX_ARRAY_BINDING,6);getInt(m,GL_ACTIVE_TEXTURE,7);
    active(m,GL_TEXTURE0);getInt(m,GL_TEXTURE_BINDING_2D,8);
    active(m,GL_TEXTURE1);getInt(m,GL_TEXTURE_BINDING_2D,9);
    m.visitVarInsn(ILOAD,7);m.visitMethodInsn(INVOKESTATIC,GL13,"glActiveTexture","(I)V",false);
    enabled(m,GL_DEPTH_TEST,10);enabled(m,GL_BLEND,11);
    integer(m,GL_DEPTH_WRITEMASK);m.visitMethodInsn(INVOKESTATIC,GL11,"glGetBoolean","(I)Z",false);m.visitVarInsn(ISTORE,12);
    m.visitInsn(ICONST_4);m.visitIntInsn(NEWARRAY,T_INT);m.visitVarInsn(ASTORE,14);
    integer(m,2978);m.visitVarInsn(ALOAD,14);m.visitMethodInsn(INVOKESTATIC,GL11,"glGetIntegerv","(I[I)V",false);
    Label start=new Label(),end=new Label(),handler=new Label(),done=new Label();
    m.visitTryCatchBlock(start,end,handler,"java/lang/Throwable");
    m.visitLabel(start);m.visitVarInsn(ALOAD,0);m.visitVarInsn(ALOAD,1);
    m.visitMethodInsn(INVOKESPECIAL,node.name,"renderOriginal",desc,false);
    m.visitLabel(end);m.visitInsn(ACONST_NULL);m.visitVarInsn(ASTORE,13);m.visitJumpInsn(GOTO,done);
    m.visitLabel(handler);m.visitVarInsn(ASTORE,13);m.visitLabel(done);restore(m);
    Label clean=new Label();m.visitVarInsn(ALOAD,13);m.visitJumpInsn(IFNULL,clean);
    m.visitVarInsn(ALOAD,13);m.visitInsn(ATHROW);m.visitLabel(clean);m.visitInsn(RETURN);m.visitMaxs(0,0);m.visitEnd();
    ClassWriter cw=new ClassWriter(ClassWriter.COMPUTE_MAXS|ClassWriter.COMPUTE_FRAMES){
      @Override protected String getCommonSuperClass(String a,String b){return a.equals(b)?a:"java/lang/Object";}
    };
    node.accept(cw);return cw.toByteArray();
  }
  public static void main(String[] args)throws Exception{
    if(args.length!=2)throw new IllegalArgumentException("INPUT_CLASS OUTPUT_CLASS");
    byte[] original=Files.readAllBytes(Path.of(args[0])),fixed=patch(original);
    Files.write(Path.of(args[1]),fixed);
    ClassNode node=new ClassNode();new ClassReader(fixed).accept(node,0);
    if(node.methods.stream().noneMatch(m->m.name.equals("renderOriginal"))||node.methods.stream().noneMatch(m->m.name.equals("render")))
      throw new IllegalStateException("Patching verification failed");
    System.out.println("PASS: renderer GL state wrapper installed");
  }
}
