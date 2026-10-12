package jp.piricraft.check;

import com.google.gson.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;
import java.util.jar.*;

/** Stages verified updates using Paper's update folder. Never reloads a plugin. */
public final class CheckAutoUpdater implements AutoCloseable {
    static final URI MANIFEST=URI.create("https://raw.githubusercontent.com/Pasta0719/Piricraft/main/update-manifest.json");
    static final String PREFIX="https://github.com/Pasta0719/Piricraft/releases/download/";
    static final int MAX_JAR=16*1024*1024;
    interface Fetch { byte[] get(URI uri,int limit)throws Exception; }
    final Path installed, update, data;
    final String runningVersion;
    final Fetch fetch;
    final Consumer<String> log;
    final ScheduledExecutorService worker;
    volatile boolean closed;
    String lastMessage="";

    public CheckAutoUpdater(Path installed,Path update,Path data,String version,Consumer<String> log) {
        this(installed,update,data,version,CheckAutoUpdater::download,log);
    }
    CheckAutoUpdater(Path installed,Path update,Path data,String version,Fetch fetch,Consumer<String> log) {
        this.installed=installed.toAbsolutePath().normalize();
        this.update=update.toAbsolutePath().normalize();this.data=data.toAbsolutePath().normalize();
        this.runningVersion=version;this.fetch=fetch;this.log=log;
        worker=Executors.newSingleThreadScheduledExecutor(r->{Thread t=new Thread(r,"PiricraftCheck-update");t.setDaemon(true);return t;});
    }
    public void start(long minutes) {
        worker.scheduleWithFixedDelay(()->{
            try { report(check()); }
            catch(Exception e){ if(!closed)report("自動更新を取得できませんでした。稼働中のCheckは維持します。次回再試行: "+e.getMessage()); }
        },5,Math.max(1,minutes)*60,TimeUnit.SECONDS);
    }
    void report(String message){if(!message.equals(lastMessage)){lastMessage=message;log.accept(message);}}
    static String sha(byte[] b)throws Exception{return HexFormat.of().withUpperCase().formatHex(MessageDigest.getInstance("SHA-256").digest(b));}
    static String fileHash(Path p)throws Exception{return sha(Files.readAllBytes(p));}
    static int compareVersion(String a,String b) {
        if(!a.matches("\\d{1,6}\\.\\d{1,6}\\.\\d{1,6}")||!b.matches("\\d{1,6}\\.\\d{1,6}\\.\\d{1,6}"))throw new IllegalArgumentException("更新バージョンの形式が不正です");
        String[] x=a.split("\\."),y=b.split("\\.");
        for(int i=0;i<3;i++){int c=Integer.compare(Integer.parseInt(x[i]),Integer.parseInt(y[i]));if(c!=0)return c;}return 0;
    }
    String check()throws Exception {
        if(closed)return "停止済み";
        if(!Files.isRegularFile(installed)||!installed.getFileName().toString().endsWith(".jar"))throw new IOException("実行元JARが見つかりません");
        if(update.equals(installed.getParent()))throw new IOException("更新先フォルダがplugins本体と同じです");
        JsonObject root=JsonParser.parseString(new String(fetch.get(MANIFEST,512*1024),StandardCharsets.UTF_8)).getAsJsonObject();
        if(!root.has("checkServer"))return "Check自動更新: 配布情報待ち";
        JsonObject c=root.getAsJsonObject("checkServer");
        String version=c.get("version").getAsString(),hash=c.get("sha256").getAsString().toUpperCase(Locale.ROOT);
        String url=c.get("url").getAsString();long size=c.get("size").getAsLong();
        int comparison=compareVersion(version,runningVersion);
        if(!version.equals(root.getAsJsonObject("launcher").get("version").getAsString()))throw new IOException("ランチャーとCheckの配布版が不一致です");
        if(!url.equals(PREFIX+"launcher-v"+version+"/PiricraftCheckServer-1.0.0.jar")||!hash.matches("[A-F0-9]{64}")||size<1||size>MAX_JAR)throw new IOException("Check配布情報が不正です");
        if(comparison<0)return "Check自動更新: 古い配布版への更新を見送りました";
        Path target=update.resolve(installed.getFileName()),marker=data.resolve("staged-update.sha256");
        String current=fileHash(installed);
        if(current.equals(hash)){
            synchronized(this){if(!closed && owned(target,marker)){Files.delete(target);Files.deleteIfExists(marker);}}
            return "Check自動更新: 最新版です（"+version+"）";
        }
        if(Files.exists(target)){
            if(fileHash(target).equals(hash))return "Check更新を準備済みです（"+version+"）。次回のサーバー再起動で適用します";
            if(!owned(target,marker))throw new IOException("更新フォルダに別のJARがあります。手動で配置した更新を優先します");
        }
        byte[] bytes=fetch.get(URI.create(url),MAX_JAR);
        if(bytes.length!=size||!sha(bytes).equals(hash))throw new IOException("ダウンロードしたJARのサイズまたはSHA-256が一致しません");
        validateJar(bytes);
        // Serialize only the final local transaction with shutdown; network never blocks disable.
        synchronized(this){
            if(closed)return "停止済み";
            Files.createDirectories(update);Files.createDirectories(data.resolve("update-backups"));
            if(Files.exists(target)&&!owned(target,marker))throw new IOException("取得中に更新先が変更されました");
            Path backup=data.resolve("update-backups").resolve(current+".jar");
            if(!Files.exists(backup))Files.copy(installed,backup);
            Path temp=Files.createTempFile(update,".piricraft-check-",".tmp");
            try{
                Files.write(temp,bytes);
                Files.move(temp,target,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
                Files.writeString(marker,hash,StandardCharsets.US_ASCII);
            }finally{Files.deleteIfExists(temp);}
        }
        return "Check更新を準備しました（"+version+"）。次回のサーバー再起動で適用します";
    }
    static boolean owned(Path target,Path marker)throws Exception {
        return Files.isRegularFile(target)&&Files.isRegularFile(marker)&&fileHash(target).equals(Files.readString(marker).trim());
    }
    static void validateJar(byte[] bytes)throws Exception {
        boolean main=false,plugin=false;
        try(var jar=new JarInputStream(new ByteArrayInputStream(bytes))){
            JarEntry e;while((e=jar.getNextJarEntry())!=null){
                if(e.getName().equals("jp/piricraft/check/PiricraftCheckPlugin.class"))main=true;
                if(e.getName().equals("plugin.yml")){
                    String text=new String(jar.readNBytes(65536),StandardCharsets.UTF_8);
                    plugin=text.matches("(?s).*?(?m)^name:\\s*PiricraftCheck\\s*$.*")&&text.contains("jp.piricraft.check.PiricraftCheckPlugin");
                }
            }
        }
        if(!main||!plugin)throw new IOException("取得ファイルはPiricraftCheckのJARではありません");
    }
    static byte[] download(URI start,int limit)throws Exception {
        URI uri=start;
        for(int redirects=0;redirects<=5;redirects++){
            if(!"https".equals(uri.getScheme())||!Set.of("github.com","raw.githubusercontent.com","release-assets.githubusercontent.com","objects.githubusercontent.com").contains(uri.getHost()))throw new IOException("更新先URLが不正です");
            HttpURLConnection connection=(HttpURLConnection)uri.toURL().openConnection();
            connection.setConnectTimeout(15000);connection.setReadTimeout(30000);connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("User-Agent","PiricraftCheck-AutoUpdater/1.0");connection.setUseCaches(false);
            try{
                int status=connection.getResponseCode();
                if(status>=300&&status<400){uri=uri.resolve(connection.getHeaderField("Location"));continue;}
                if(status!=200)throw new IOException("HTTP "+status);
                if(connection.getContentLengthLong()>limit)throw new IOException("更新ファイルが大きすぎます");
                try(InputStream input=connection.getInputStream()){
                    byte[] bytes=input.readNBytes(limit+1);if(bytes.length>limit)throw new IOException("取得サイズが上限を超えました");return bytes;
                }
            }finally{connection.disconnect();}
        }
        throw new IOException("リダイレクト回数が上限を超えました");
    }
    @Override public synchronized void close(){closed=true;worker.shutdownNow();}
}
