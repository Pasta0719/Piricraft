package jp.piricraft.check;

import com.google.gson.*;
import java.io.*;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.jar.*;

public class CheckAutoUpdaterTest {
    static byte[] jar(String marker)throws Exception{
        var out=new ByteArrayOutputStream();
        try(var zip=new JarOutputStream(out)){
            zip.putNextEntry(new JarEntry("plugin.yml"));zip.write("name: PiricraftCheck\nmain: jp.piricraft.check.PiricraftCheckPlugin\n".getBytes(StandardCharsets.UTF_8));zip.closeEntry();
            zip.putNextEntry(new JarEntry("jp/piricraft/check/PiricraftCheckPlugin.class"));zip.write(marker.getBytes());zip.closeEntry();
        }return out.toByteArray();
    }
    static class Remote implements CheckAutoUpdater.Fetch {
        byte[] artifact;String version="1.1.27",hash;long size;boolean fail;int downloads;
        Remote(byte[] artifact)throws Exception{this.artifact=artifact;hash=CheckAutoUpdater.sha(artifact);size=artifact.length;}
        public byte[] get(URI uri,int limit)throws Exception{
            if(fail)throw new IOException("test offline");
            if(uri.equals(CheckAutoUpdater.MANIFEST)){
                var root=new JsonObject();var launcher=new JsonObject();launcher.addProperty("version",version);root.add("launcher",launcher);
                var c=new JsonObject();c.addProperty("version",version);c.addProperty("url",CheckAutoUpdater.PREFIX+"launcher-v"+version+"/PiricraftCheckServer-1.0.0.jar");c.addProperty("sha256",hash);c.addProperty("size",size);root.add("checkServer",c);
                return root.toString().getBytes(StandardCharsets.UTF_8);
            }downloads++;return artifact;
        }
    }
    static void require(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        Path dir=Files.createTempDirectory("piricraft-updater-test-");
        Path installed=dir.resolve("plugins/PiricraftCheckServer-1.0.0.jar"),update=dir.resolve("plugins/update"),data=dir.resolve("plugins/PiricraftCheck");
        Files.createDirectories(installed.getParent());byte[] old=jar("old"),next=jar("new");Files.write(installed,old);
        Remote remote=new Remote(next);
        try(var updater=new CheckAutoUpdater(installed,update,data,"1.1.26",remote,s->{})){
            updater.check();Path staged=update.resolve(installed.getFileName());
            require(CheckAutoUpdater.fileHash(installed).equals(CheckAutoUpdater.sha(old)),"live JAR changed");
            require(CheckAutoUpdater.fileHash(staged).equals(CheckAutoUpdater.sha(next)),"not staged");
            require(Files.exists(data.resolve("update-backups/"+CheckAutoUpdater.sha(old)+".jar")),"missing backup");
            updater.check();require(remote.downloads==1,"repeated download");
            remote.fail=true;try{updater.check();throw new AssertionError("offline");}catch(IOException expected){}
            require(CheckAutoUpdater.fileHash(staged).equals(CheckAutoUpdater.sha(next)),"offline damaged pending update");remote.fail=false;
            // Simulate Paper applying the staged file at restart.
            Files.move(staged,installed,StandardCopyOption.REPLACE_EXISTING);updater.check();require(!Files.exists(staged),"same release restaged");
            remote.artifact=jar("third");remote.hash="0".repeat(64);remote.size=remote.artifact.length;
            try{updater.check();throw new AssertionError("bad hash accepted");}catch(IOException expected){}
            require(!Files.exists(staged),"bad hash staged");
            remote.hash=CheckAutoUpdater.sha(remote.artifact);remote.size++;
            try{updater.check();throw new AssertionError("bad size accepted");}catch(IOException expected){}
            remote.size--;Files.write(staged,old);
            try{updater.check();throw new AssertionError("foreign pending overwritten");}catch(IOException expected){}
            require(CheckAutoUpdater.fileHash(staged).equals(CheckAutoUpdater.sha(old)),"foreign update changed");Files.delete(staged);
            remote.version="1.1.25";updater.check();require(!Files.exists(staged),"downgrade staged");
            remote.version="1.1.27";updater.close();updater.check();require(!Files.exists(staged),"disabled updater staged");
        }
        try{CheckAutoUpdater.validateJar("invalid".getBytes());throw new AssertionError("invalid JAR accepted");}catch(IOException expected){}
        require(CheckAutoUpdater.compareVersion("1.1.100","1.1.99")>0,"version ordering");
        System.out.println("PASS: stage, live JAR unchanged, backup, idempotence, offline, restart, hash/size rejection, foreign update, downgrade, disable, JAR validation");
    }
}
