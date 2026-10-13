import java.nio.file.Files;
import java.nio.file.Path;
import jdk.internal.org.objectweb.asm.ClassReader;
import jdk.internal.org.objectweb.asm.ClassWriter;
import jdk.internal.org.objectweb.asm.tree.*;

/**
 * Minimal bytecode repair for published Abyss 0.1.3:
 * its exception handler was typed as Object instead of Exception.
 * This can cause a JVM VerifyError before the game reaches the main menu.
 * No instructions or GL/shader logic are replaced by this tool.
 */
public final class AbyssFrameFix {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("input.class output.class");
        ClassNode node = new ClassNode();
        new ClassReader(Files.readAllBytes(Path.of(args[0]))).accept(node, 0);
        int fixed = 0;
        for (MethodNode method : node.methods) {
            if (!method.name.equals("renderOriginal") ||
                    !method.desc.contains("WorldRenderContext")) continue;
            for (TryCatchBlockNode handler : method.tryCatchBlocks) {
                if (!"java/lang/RuntimeException".equals(handler.type) &&
                    !"java/io/IOException".equals(handler.type)) continue;
                AbstractInsnNode after = handler.handler.getNext();
                while (after instanceof LineNumberNode || after instanceof LabelNode) after = after.getNext();
                if (!(after instanceof FrameNode frame) || frame.stack == null ||
                    frame.stack.size() != 1) throw new IllegalStateException("Invalid exception handler stack");
                Object type = frame.stack.get(0);
                if (!"java/lang/Object".equals(type) &&
                    !"java/lang/Exception".equals(type)) throw new IllegalStateException("Unexpected handler type: " + type);
                if ("java/lang/Object".equals(type)) {
                    frame.stack.set(0, "java/lang/Exception");
                    fixed++;
                }
            }
        }
        if (fixed != 1) throw new IllegalStateException("Expected exactly one corrupt handler, got " + fixed);
        ClassWriter writer = new ClassWriter(0); // Preserve all existing bytecode/frames except the repair.
        node.accept(writer);
        Files.write(Path.of(args[1]), writer.toByteArray());
        System.out.println("PASS: exact handler frame repaired: Object -> Exception");
    }
}
