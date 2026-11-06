package dev.lokey.otablocker;

import android.content.ComponentName;
import android.content.pm.ApplicationInfo;
import android.content.pm.ComponentInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.system.Os;
import android.system.OsConstants;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/** Root app_process entry point; caller must hold the shared operation lock. */
public final class Main {
    private static final long FLAGS = PackageManager.GET_ACTIVITIES | PackageManager.GET_SERVICES
            | PackageManager.GET_RECEIVERS | PackageManager.GET_PROVIDERS
            | PackageManager.MATCH_DISABLED_COMPONENTS | PackageManager.MATCH_DIRECT_BOOT_AWARE
            | PackageManager.MATCH_DIRECT_BOOT_UNAWARE;
    private static int emitted;
    private static final class Rule {
        String kind, pkg, component;
        boolean core;
        String key() { return kind + "|" + pkg + "|" + component; }
    }
    private static final class Target {
        final int user, state, appState;
        final Rule rule;
        final boolean manifestEnabled, appEnabled;
        Target(int user, Rule rule, int state, boolean enabled, int appState, boolean appEnabled) {
            this.user=user; this.rule=rule; this.state=state; this.manifestEnabled=enabled;
            this.appState=appState; this.appEnabled=appEnabled;
        }
        String key() { return user + "|" + rule.key(); }
        int desired() { return "package".equals(rule.kind) ? 3 : 2; }
        boolean blocked() { return state == 2 || state == 3; }
        boolean effective() {
            return (appState == 1 || (appState == 0 && appEnabled))
                    && (state == 1 || (state == 0 && manifestEnabled));
        }
    }
    private static final class PackageView {
        final int user, appState;
        final String name, identity;
        final PackageInfo info;
        final Map<String,ComponentInfo> components = new TreeMap<>();
        final Map<String,String> types = new TreeMap<>();
        PackageView(int user, String name, PackageInfo info, int appState) {
            this.user=user; this.name=name; this.info=info; this.appState=appState;
            this.identity=identity(info);
            if (info != null) {
                add(info.activities,"activity"); add(info.receivers,"receiver");
                add(info.services,"service"); add(info.providers,"provider");
            }
        }
        void add(ComponentInfo[] values, String type) {
            if (values == null) return;
            for (ComponentInfo c : values) if (c != null && c.name != null) {
                String full = normalize(name,c.name); components.put(full,c); types.put(full,type);
            }
        }
        String key() { return user + "|" + name; }
    }
    private static final class Snapshot {
        final Map<String,PackageView> packages = new LinkedHashMap<>();
        final Map<String,Target> targets = new LinkedHashMap<>();
        final Set<Integer> supported = new LinkedHashSet<>();
        final Set<Integer> installedUsers = new LinkedHashSet<>();
        int missing;
    }
    private static final class Entry {
        int user, original;
        String kind,pkg,component;
        String key() { return user + "|" + kind + "|" + pkg + "|" + component; }
        static Entry from(Target t) {
            Entry e=new Entry(); e.user=t.user; e.kind=t.rule.kind; e.pkg=t.rule.pkg;
            e.component=t.rule.component; e.original=t.state; return e;
        }
        JSONObject json() throws Exception {
            JSONObject o=new JSONObject(); o.put("user",user); o.put("kind",kind);
            o.put("package",pkg); o.put("component",component); o.put("original",original); return o;
        }
    }
    /** Atomic write-ahead records preserve each target's first observed setting. */
    private static final class Journal {
        final File directory,file;
        final Map<String,Entry> entries=new LinkedHashMap<>();
        Journal(File directory) throws Exception {
            this.directory=directory; this.file=new File(directory,"journal.json");
            if (!file.exists()) return;
            JSONObject root=new JSONObject(read(file,4*1024*1024));
            if (strictInt(root,"schema") != 1) throw new IOException("Unknown journal schema");
            JSONArray values=root.getJSONArray("entries");
            if (values.length()>20000) throw new IOException("Journal entry limit exceeded");
            for (int i=0;i<values.length();i++) {
                JSONObject o=values.getJSONObject(i); Entry e=new Entry();
                e.user=strictInt(o,"user"); e.original=strictInt(o,"original");
                e.kind=o.getString("kind"); e.pkg=o.getString("package"); e.component=o.getString("component");
                validateTarget(e.kind,e.pkg,e.component);
                if (e.user<0 || e.original<0 || e.original>4) throw new IOException("Invalid journal state");
                if (entries.put(e.key(),e)!=null) throw new IOException("Duplicate journal entry");
            }
        }
        void save() throws Exception {
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create state directory");
            JSONObject root=new JSONObject(); root.put("schema",1); JSONArray values=new JSONArray();
            for (Entry e:entries.values()) values.put(e.json()); root.put("entries",values);
            File temporary=File.createTempFile("journal-",".tmp",directory);
            try {
                Os.chmod(temporary.getAbsolutePath(),0600);
                try (FileOutputStream out=new FileOutputStream(temporary)) {
                    out.write((root.toString()+"\n").getBytes(StandardCharsets.UTF_8));
                    out.flush(); out.getFD().sync();
                }
                Os.rename(temporary.getAbsolutePath(),file.getAbsolutePath());
                // O_DIRECTORY is not exposed by the public SDK; the directory was checked above.
                FileDescriptor fd=Os.open(directory.getAbsolutePath(),OsConstants.O_RDONLY,0);
                try { Os.fsync(fd); } finally { Os.close(fd); }
            } finally {
                if (temporary.exists() && !temporary.delete()) diagnostic("temporary_journal_cleanup_failed");
            }
        }
        void prepare(List<Target> targets) throws Exception {
            boolean added=false;
            for (Target t:targets) if (!entries.containsKey(t.key())) {
                entries.put(t.key(),Entry.from(t)); added=true;
            }
            if (added) save(); // Durability precedes the setter, including the very first setter.
        }
    }
    /** Hidden Binder APIs are reflected to tolerate long/int flags and old setter signatures. */
    private static final class Backend {
        final Object pm;
        final Method packageInfo,componentGet,appGet,componentSet,appSet;
        Method batchSet;
        Constructor<?> batchItem;
        Backend() throws Exception {
            Method getter=Class.forName("android.app.ActivityThread").getDeclaredMethod("getPackageManager");
            getter.setAccessible(true); pm=getter.invoke(null);
            if (pm==null) throw new IOException("PackageManager unavailable");
            Class<?> type=Class.forName("android.content.pm.IPackageManager");
            Method found=null;
            for (Method m:type.getMethods()) {
                Class<?>[] p=m.getParameterTypes();
                if (m.getName().equals("getPackageInfo") && p.length==3 && p[0]==String.class
                        && (p[1]==long.class || p[1]==int.class) && p[2]==int.class) {
                    found=m; if (p[1]==long.class) break;
                }
            }
            if (found==null) throw new NoSuchMethodException("getPackageInfo");
            packageInfo=found;
            componentGet=type.getMethod("getComponentEnabledSetting",ComponentName.class,int.class);
            appGet=type.getMethod("getApplicationEnabledSetting",String.class,int.class);
            componentSet=setter(type,"setComponentEnabledSetting",ComponentName.class);
            appSet=setter(type,"setApplicationEnabledSetting",String.class);
            if (Build.VERSION.SDK_INT>=33) try {
                batchSet=type.getMethod("setComponentEnabledSettings",List.class,int.class,String.class);
                batchItem=Class.forName("android.content.pm.PackageManager$ComponentEnabledSetting")
                        .getConstructor(ComponentName.class,int.class,int.class);
            } catch (ReflectiveOperationException unavailable) { batchSet=null; batchItem=null; }
        }
        static Method setter(Class<?> type,String name,Class<?> first) throws Exception {
            try { return type.getMethod(name,first,int.class,int.class,int.class,String.class); }
            catch (NoSuchMethodException older) { return type.getMethod(name,first,int.class,int.class,int.class); }
        }
        PackageInfo info(String name,int user) throws Exception {
            Object flags;
            if (packageInfo.getParameterTypes()[1]==long.class) flags=Long.valueOf(FLAGS);
            else flags=Integer.valueOf((int)FLAGS);
            PackageInfo value;
            try { value=(PackageInfo)invoke(packageInfo,pm,name,flags,user); }
            catch (PackageManager.NameNotFoundException missing) { return null; }
            if (value==null) return null;
            if (!name.equals(value.packageName) || value.applicationInfo==null)
                throw new IOException("Incomplete PackageInfo: "+name);
            return (value.applicationInfo.flags & ApplicationInfo.FLAG_INSTALLED)==0 ? null : value;
        }
        int component(String pkg,String name,int user) throws Exception {
            return checkedState((Integer)invoke(componentGet,pm,new ComponentName(pkg,name),user));
        }
        int app(String pkg,int user) throws Exception { return checkedState((Integer)invoke(appGet,pm,pkg,user)); }
        void set(String kind,String pkg,String name,int user,int state) throws Exception {
            Method method="package".equals(kind)?appSet:componentSet;
            Object first="package".equals(kind)?pkg:new ComponentName(pkg,name);
            // Do not terminate the entire GMS process for one OTA component change.
            if (method.getParameterTypes().length==5)
                invoke(method,pm,first,state,PackageManager.DONT_KILL_APP,user,null);
            else invoke(method,pm,first,state,PackageManager.DONT_KILL_APP,user);
        }
        void batch(List<Target> targets) throws Exception {
            List<Object> settings=new ArrayList<>();
            for (Target t:targets) settings.add(batchItem.newInstance(
                    new ComponentName(t.rule.pkg,t.rule.component),t.desired(),PackageManager.DONT_KILL_APP));
            invoke(batchSet,pm,settings,targets.get(0).user,null);
        }
    }
    public static void main(String[] args) {
        int code;
        try { code=run(args); }
        catch (Exception e) { diagnostic("error="+describe(e)); counts(0,0,0,1,0); result("error"); code=4; }
        System.exit(code);
    }
    private static int run(String[] args) throws Exception {
        if (args.length!=5) throw new IllegalArgumentException(
                "Usage: Main status|apply|restore|inventory stateDir profilesDir profilesCsv usersCsv");
        String command=args[0];
        if (!Arrays.asList("status","apply","restore","inventory").contains(command))
            throw new IllegalArgumentException("Unknown command");
        Journal journal=new Journal(new File(args[1])); Backend backend=new Backend();
        if (command.equals("restore")) return restore(backend,journal);
        List<Rule> rules=profiles(new File(args[2]),args[3]); List<Integer> users=users(args[4]);
        Snapshot before=snapshot(backend,rules,users);
        show(before,journal,command.equals("inventory"),backend);
        int unselected=0;
        for (String key:journal.entries.keySet()) if (!before.targets.containsKey(key)) unselected++;
        if (unselected!=0) diagnostic("journal_targets_outside_current_selection="+unselected);
        if (before.supported.isEmpty()) {
            counts(0,0,before.missing,0,0); result("unsupported"); return 3;
        }
        if (!command.equals("apply")) return evaluate(before,0,0);
        int setterErrors=0;
        Map<String,List<Target>> groups=new LinkedHashMap<>();
        for (Target t:before.targets.values()) {
            if (!before.supported.contains(t.user) || t.blocked()) continue;
            String group=t.user+"|"+t.rule.pkg+"|"+t.rule.kind;
            List<Target> list=groups.get(group);
            if (list==null) { list=new ArrayList<>(); groups.put(group,list); }
            list.add(t);
        }
        for (List<Target> values:groups.values()) {
            if (backend.batchSet!=null && values.get(0).rule.kind.equals("component") && values.size()>1) {
                journal.prepare(values);
                try { backend.batch(values); }
                catch (Exception e) {
                    setterErrors+=values.size();
                    diagnostic("batch_failed="+values.get(0).rule.pkg+" user="+values.get(0).user+" "+describe(e));
                }
            } else for (Target t:values) {
                journal.prepare(Collections.singletonList(t));
                try { backend.set(t.rule.kind,t.rule.pkg,t.rule.component,t.user,t.desired()); }
                catch (Exception e) { setterErrors++; diagnostic("set_failed="+t.key()+" "+describe(e)); }
            }
        }
        Snapshot after;
        try { after=snapshot(backend,rules,users); }
        catch (Exception e) {
            diagnostic("post_apply_inventory_failed="+describe(e));
            counts(0,0,before.missing,setterErrors+1,before.supported.size()); result("degraded"); return 2;
        }
        int changed=0;
        for (Target t:before.targets.values()) {
            Target next=after.targets.get(t.key());
            if (!t.blocked() && next!=null && next.blocked()) changed++;
        }
        if (!sameIdentities(before,after)) {
            setterErrors++; diagnostic("package_identity_changed_during_apply=retry_required");
        }
        show(after,journal,false,backend); return evaluate(after,changed,setterErrors);
    }
    private static Snapshot snapshot(Backend backend,List<Rule> rules,List<Integer> users) throws Exception {
        Snapshot out=new Snapshot(); Set<String> names=new LinkedHashSet<>();
        for (Rule r:rules) names.add(r.pkg);
        for (int user:users) {
            for (String pkg:names) {
                PackageInfo info=backend.info(pkg,user);
                PackageView view=new PackageView(user,pkg,info,info==null?-1:backend.app(pkg,user));
                out.packages.put(view.key(),view); if (info!=null) out.installedUsers.add(user);
            }
            for (Rule r:rules) {
                PackageView view=out.packages.get(user+"|"+r.pkg);
                ComponentInfo component=view.components.get(r.component);
                if (view.info==null || (r.kind.equals("component") && component==null)) { out.missing++; continue; }
                int state=r.kind.equals("package")?view.appState:backend.component(r.pkg,r.component,user);
                Target t=new Target(user,r,state,component==null?view.info.applicationInfo.enabled:component.enabled,
                        view.appState,view.info.applicationInfo.enabled);
                out.targets.put(t.key(),t); if (r.core) out.supported.add(user);
            }
        }
        // Reject a partial view collected during a package replacement before any mutation.
        for (PackageView view:out.packages.values())
            if (!view.identity.equals(identity(backend.info(view.name,view.user))))
                throw new IOException("Package changed during inventory: "+view.key());
        return out;
    }
    private static int evaluate(Snapshot snapshot,int changed,int extraFailed) {
        int blocked=0,failed=extraFailed;
        if (snapshot.supported.isEmpty()) {
            counts(changed,0,snapshot.missing,failed,0); result("unsupported"); return 3;
        }
        for (int user:snapshot.installedUsers) if (!snapshot.supported.contains(user)) {
            failed++; diagnostic("user_without_core_capability="+user);
        }
        for (Target t:snapshot.targets.values()) {
            if (!snapshot.supported.contains(t.user)) continue;
            if (t.blocked()) blocked++; else { failed++; diagnostic("target_not_blocked="+t.key()+" state="+t.state); }
        }
        counts(changed,Math.max(0,blocked-changed),snapshot.missing,failed,snapshot.supported.size());
        result(failed==0?"blocked":"degraded"); return failed==0?0:2;
    }
    private static int restore(Backend backend,Journal journal) throws Exception {
        int changed=0,already=0,missing=0,failed=0;
        List<Entry> entries=new ArrayList<>(journal.entries.values());
        for (Entry e:entries) try {
            PackageInfo info=backend.info(e.pkg,e.user);
            if (info==null) { missing++; diagnostic("restore_package_missing="+e.key()); continue; }
            PackageView view=new PackageView(e.user,e.pkg,info,backend.app(e.pkg,e.user));
            if (e.kind.equals("component") && !view.components.containsKey(e.component)) {
                missing++; diagnostic("restore_component_missing="+e.key()); continue;
            }
            int current=e.kind.equals("package")?view.appState:backend.component(e.pkg,e.component,e.user);
            if (current!=e.original) backend.set(e.kind,e.pkg,e.component,e.user,e.original);
            int actual=e.kind.equals("package")?backend.app(e.pkg,e.user):backend.component(e.pkg,e.component,e.user);
            if (actual!=e.original) throw new IOException("Restore readback mismatch");
            if (!view.identity.equals(identity(backend.info(e.pkg,e.user))))
                throw new IOException("Package replaced during restore");
            journal.entries.remove(e.key()); if (current==e.original) already++; else changed++;
        } catch (Exception error) { failed++; diagnostic("restore_pending="+e.key()+" "+describe(error)); }
        // Crash before the save only repeats an idempotent restore next time.
        if (journal.entries.size()!=entries.size()) journal.save();
        diagnostic("restore_pending_entries="+journal.entries.size()); counts(changed,already,missing,failed,0);
        boolean complete=journal.entries.isEmpty(); result(complete?"restored":"degraded"); return complete?0:2;
    }
    private static void show(Snapshot snapshot,Journal journal,boolean discovered,Backend backend) throws Exception {
        for (PackageView view:snapshot.packages.values()) {
            if (view.info==null) { line("PACKAGE|user="+view.user+"|package="+view.name+"|installed=false"); continue; }
            line("PACKAGE|user="+view.user+"|package="+view.name+"|installed=true|version="+version(view.info)
                    +"|updated="+view.info.lastUpdateTime+"|app_state="+view.appState
                    +"|source="+clean(view.info.applicationInfo.sourceDir));
            if (!snapshot.supported.contains(view.user)) diagnostic("user_skipped_without_core="+view.user);
            if (discovered) for (Map.Entry<String,ComponentInfo> value:view.components.entrySet()) {
                if (!value.getKey().contains(".update.")) continue;
                line("DISCOVERED|user="+view.user+"|package="+view.name+"|component="+clean(value.getKey())
                        +"|type="+view.types.get(value.getKey())
                        +"|state="+backend.component(view.name,value.getKey(),view.user)
                        +"|manifest_enabled="+value.getValue().enabled);
            }
        }
        for (Target t:snapshot.targets.values()) {
            Entry e=journal.entries.get(t.key());
            line("TARGET|user="+t.user+"|type="+t.rule.kind+"|package="+t.rule.pkg+"|component="+t.rule.component
                    +"|state="+t.state+"|effective="+(t.effective()?"enabled":"disabled")
                    +"|core="+t.rule.core+"|original="+(e==null?"untracked":e.original));
        }
    }
    private static List<Rule> profiles(File directory,String csv) throws Exception {
        Map<String,Rule> rules=new LinkedHashMap<>(); Set<String> ids=new LinkedHashSet<>();
        for (String id:csv.split(",",-1)) {
            if (!id.matches("[a-z][a-z0-9_-]{0,31}")) throw new IOException("Invalid profile id");
            if (!ids.add(id)) continue;
            File file=new File(directory,id+".profile");
            if (!file.getCanonicalFile().getParentFile().equals(directory.getCanonicalFile()))
                throw new IOException("Profile escapes profiles directory");
            int number=0;
            for (String raw:read(file,128*1024).split("\n")) {
                number++; String value=raw.trim(); if (value.isEmpty() || value.startsWith("#")) continue;
                String[] fields=value.split("\\|",-1);
                if (fields.length!=4) throw new IOException("Invalid rule at "+id+":"+number);
                Rule r=new Rule(); r.kind=fields[0]; r.pkg=fields[1]; r.component=fields[2];
                validateTarget(r.kind,r.pkg,r.component);
                if (!fields[3].equals("core") && !fields[3].equals("optional")) throw new IOException("Invalid rule priority");
                r.core=fields[3].equals("core");
                if (r.core && !r.kind.equals("component")) throw new IOException("Only component rules may be core");
                Rule previous=rules.get(r.key());
                if (previous==null) rules.put(r.key(),r); else previous.core|=r.core;
                if (rules.size()>4096) throw new IOException("Profile rule limit exceeded");
            }
        }
        if (rules.isEmpty()) throw new IOException("No configured profile targets");
        return new ArrayList<>(rules.values());
    }
    private static List<Integer> users(String csv) throws Exception {
        Set<Integer> values=new LinkedHashSet<>();
        for (String text:csv.split(",",-1)) {
            if (!text.matches("[0-9]{1,10}")) throw new IOException("Invalid user id");
            int user=Integer.parseInt(text); if (user<0) throw new IOException("Invalid user id"); values.add(user);
        }
        if (values.size()>64) throw new IOException("User limit exceeded"); return new ArrayList<>(values);
    }
    private static void validateTarget(String kind,String pkg,String component) throws Exception {
        if (!pkg.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")) throw new IOException("Invalid package name");
        if (kind.equals("package")) {
            if (!component.equals("-")) throw new IOException("Invalid package target");
        } else if (kind.equals("component")) {
            if (!component.matches("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)+"))
                throw new IOException("Component must be fully qualified");
        } else throw new IOException("Invalid target type");
    }
    private static int strictInt(JSONObject o,String key) throws Exception {
        Object value=o.get(key); if (!(value instanceof Integer)) throw new IOException("Invalid integer field: "+key);
        return (Integer)value;
    }
    private static int checkedState(int state) throws IOException {
        if (state<0 || state>4) throw new IOException("Unknown enabled setting: "+state); return state;
    }
    private static Object invoke(Method method,Object receiver,Object... args) throws Exception {
        try { return method.invoke(receiver,args); }
        catch (InvocationTargetException wrapper) {
            Throwable cause=wrapper.getCause(); if (cause instanceof Exception) throw (Exception)cause;
            throw new IOException("Binder invocation failed",cause);
        }
    }
    private static String normalize(String pkg,String name) {
        if (name.startsWith(".")) return pkg+name; return name.contains(".")?name:pkg+"."+name;
    }
    private static long version(PackageInfo info) {
        return Build.VERSION.SDK_INT>=28?info.getLongVersionCode():info.versionCode;
    }
    private static String identity(PackageInfo info) {
        if (info==null) return "absent";
        String[] splits=info.applicationInfo.splitSourceDirs;
        if (splits==null) splits=new String[0]; else splits=splits.clone(); Arrays.sort(splits);
        return version(info)+":"+info.lastUpdateTime+":"+info.applicationInfo.sourceDir+":"+Arrays.toString(splits);
    }
    private static boolean sameIdentities(Snapshot first,Snapshot second) {
        if (!first.packages.keySet().equals(second.packages.keySet())) return false;
        for (String key:first.packages.keySet())
            if (!first.packages.get(key).identity.equals(second.packages.get(key).identity)) return false;
        return true;
    }
    private static String read(File file,int limit) throws IOException {
        try (FileInputStream in=new FileInputStream(file); ByteArrayOutputStream out=new ByteArrayOutputStream()) {
            byte[] buffer=new byte[4096]; int length;
            while ((length=in.read(buffer))!=-1) {
                if (out.size()+length>limit) throw new IOException("Input file exceeds limit"); out.write(buffer,0,length);
            }
            return new String(out.toByteArray(),StandardCharsets.UTF_8);
        }
    }
    private static String describe(Exception e) { return e.getClass().getSimpleName()+": "+clean(e.getMessage()); }
    private static String clean(String text) {
        if (text==null) return "-";
        String safe=text.replace('\n',' ').replace('\r',' ').replace('|','/');
        return safe.length()>700?safe.substring(0,700):safe;
    }
    private static void line(String text) {
        if (emitted++<500) System.out.println(text);
        else if (emitted==501) System.out.println("DIAG|output_truncated=true");
    }
    private static void diagnostic(String text) { line("DIAG|"+clean(text)); }
    private static void counts(int changed,int already,int missing,int failed,int supported) {
        System.out.println("COUNTS|changed="+changed+"|already="+already+"|missing="+missing
                +"|failed="+failed+"|supported_users="+supported);
    }
    private static void result(String value) { System.out.println("RESULT|"+value); }
}
