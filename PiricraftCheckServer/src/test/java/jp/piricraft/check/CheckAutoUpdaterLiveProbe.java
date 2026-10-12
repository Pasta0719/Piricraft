package jp.piricraft.check;
import java.nio.file.*;

/** Read-only remote check, with all staging isolated under the supplied local directory. */
public class CheckAutoUpdaterLiveProbe {
    public static void main(String[] args)throws Exception{
        Path root=Path.of(args[1]),installed=root.resolve("plugins/PiricraftCheckServer-1.0.0.jar");
        Files.createDirectories(installed.getParent());Files.copy(Path.of(args[0]),installed,StandardCopyOption.REPLACE_EXISTING);
        String original=CheckAutoUpdater.fileHash(installed);
        try(var updater=new CheckAutoUpdater(installed,root.resolve("plugins/update"),root.resolve("plugins/PiricraftCheck"),"1.1.26",System.out::println)){
            System.out.println(updater.check());
            Path staged=root.resolve("plugins/update/PiricraftCheckServer-1.0.0.jar");
            if(!Files.isRegularFile(staged)||!CheckAutoUpdater.fileHash(installed).equals(original))throw new AssertionError("live staging failed");
            System.out.println("LIVE_UPDATE_STAGED_SHA256="+CheckAutoUpdater.fileHash(staged));
            System.out.println(updater.check());
        }
    }
}
