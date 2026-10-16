const std = @import("std");

// ============================================================================
// JNI Базовые типы данных (JNI Specification 1.8+)
// ============================================================================

pub const jobject = ?*anyopaque;
pub const jclass = jobject;
pub const jfieldID = ?*anyopaque;
pub const jmethodID = ?*anyopaque;
pub const jstring = jobject;
pub const jboolean = u8;
pub const jbyte = i8;
pub const jchar = u16;
pub const jshort = i16;
pub const jint = i32;
pub const jlong = i64;
pub const jfloat = f32;
pub const jdouble = f64;
pub const jsize = jint;
pub const jobjectArray = jobject;

pub const jvalue = extern union {
    z: jboolean,
    b: jbyte,
    c: jchar,
    s: jshort,
    i: jint,
    j: jlong,
    f: jfloat,
    d: jdouble,
    l: jobject,
};

pub const JNINativeInterface = extern struct {
    reserved0: ?*anyopaque = null,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,
    reserved3: ?*anyopaque = null,

    GetVersion: ?*const fn (env: *JNIEnv) callconv(.c) jint = null,
    DefineClass: ?*anyopaque = null,
    FindClass: ?*const fn (env: *JNIEnv, name: [*:0]const u8) callconv(.c) jclass = null,
    FromReflectedMethod: ?*anyopaque = null,
    FromReflectedField: ?*anyopaque = null,
    ToReflectedMethod: ?*anyopaque = null,
    GetSuperclass: ?*anyopaque = null,
    IsAssignableFrom: ?*anyopaque = null,
    ToReflectedField: ?*anyopaque = null,

    Throw: ?*anyopaque = null,
    ThrowNew: ?*anyopaque = null,
    ExceptionOccurred: ?*const fn (env: *JNIEnv) callconv(.c) jobject = null,
    ExceptionDescribe: ?*const fn (env: *JNIEnv) callconv(.c) void = null,
    ExceptionClear: ?*const fn (env: *JNIEnv) callconv(.c) void = null,
    FatalError: ?*anyopaque = null,

    PushLocalFrame: ?*const fn (env: *JNIEnv, capacity: jint) callconv(.c) jint = null,
    PopLocalFrame: ?*const fn (env: *JNIEnv, result: jobject) callconv(.c) jobject = null,
    NewGlobalRef: ?*const fn (env: *JNIEnv, obj: jobject) callconv(.c) jobject = null,
    DeleteGlobalRef: ?*const fn (env: *JNIEnv, obj: jobject) callconv(.c) void = null,
    DeleteLocalRef: ?*const fn (env: *JNIEnv, obj: jobject) callconv(.c) void = null,
    IsSameObject: ?*anyopaque = null,
    NewLocalRef: ?*anyopaque = null,
    EnsureLocalCapacity: ?*anyopaque = null,

    AllocObject: ?*anyopaque = null,
    NewObject: ?*anyopaque = null,
    NewObjectA: ?*const fn (env: *JNIEnv, clazz: jclass, methodID: jmethodID, args: [*]const jvalue) callconv(.c) jobject = null,
    NewObjectV: ?*anyopaque = null,

    GetObjectClass: ?*const fn (env: *JNIEnv, obj: jobject) callconv(.c) jclass = null,
    IsInstanceOf: ?*const fn (env: *JNIEnv, obj: jobject, clazz: jclass) callconv(.c) jboolean = null,
    GetMethodID: ?*const fn (env: *JNIEnv, clazz: jclass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) jmethodID = null,

    CallObjectMethod: ?*const fn (env: *JNIEnv, obj: jobject, methodID: jmethodID, ...) callconv(.c) jobject = null,
    CallObjectMethodV: ?*anyopaque = null,
    CallObjectMethodA: ?*anyopaque = null,
    CallBooleanMethod: ?*const fn (env: *JNIEnv, obj: jobject, methodID: jmethodID, ...) callconv(.c) jboolean = null,
    CallBooleanMethodV: ?*anyopaque = null,
    CallBooleanMethodA: ?*anyopaque = null,
    CallByteMethod: ?*anyopaque = null,
    CallByteMethodV: ?*anyopaque = null,
    CallByteMethodA: ?*anyopaque = null,
    CallCharMethod: ?*anyopaque = null,
    CallCharMethodV: ?*anyopaque = null,
    CallCharMethodA: ?*anyopaque = null,
    CallShortMethod: ?*anyopaque = null,
    CallShortMethodV: ?*anyopaque = null,
    CallShortMethodA: ?*anyopaque = null,
    CallIntMethod: ?*const fn (env: *JNIEnv, obj: jobject, methodID: jmethodID, ...) callconv(.c) jint = null,
    CallIntMethodV: ?*anyopaque = null,
    CallIntMethodA: ?*anyopaque = null,
    CallLongMethod: ?*const fn (env: *JNIEnv, obj: jobject, methodID: jmethodID, ...) callconv(.c) jlong = null,
    CallLongMethodV: ?*anyopaque = null,
    CallLongMethodA: ?*anyopaque = null,
    CallFloatMethod: ?*anyopaque = null,
    CallFloatMethodV: ?*anyopaque = null,
    CallFloatMethodA: ?*anyopaque = null,
    CallDoubleMethod: ?*anyopaque = null,
    CallDoubleMethodV: ?*anyopaque = null,
    CallDoubleMethodA: ?*anyopaque = null,
    CallVoidMethod: ?*const fn (env: *JNIEnv, obj: jobject, methodID: jmethodID, ...) callconv(.c) void = null,
    CallVoidMethodV: ?*anyopaque = null,
    CallVoidMethodA: ?*anyopaque = null,

    CallNonvirtualObjectMethod: ?*anyopaque = null,
    CallNonvirtualObjectMethodV: ?*anyopaque = null,
    CallNonvirtualObjectMethodA: ?*anyopaque = null,
    CallNonvirtualBooleanMethod: ?*anyopaque = null,
    CallNonvirtualBooleanMethodV: ?*anyopaque = null,
    CallNonvirtualBooleanMethodA: ?*anyopaque = null,
    CallNonvirtualByteMethod: ?*anyopaque = null,
    CallNonvirtualByteMethodV: ?*anyopaque = null,
    CallNonvirtualByteMethodA: ?*anyopaque = null,
    CallNonvirtualCharMethod: ?*anyopaque = null,
    CallNonvirtualCharMethodV: ?*anyopaque = null,
    CallNonvirtualCharMethodA: ?*anyopaque = null,
    CallNonvirtualShortMethod: ?*anyopaque = null,
    CallNonvirtualShortMethodV: ?*anyopaque = null,
    CallNonvirtualShortMethodA: ?*anyopaque = null,
    CallNonvirtualIntMethod: ?*anyopaque = null,
    CallNonvirtualIntMethodV: ?*anyopaque = null,
    CallNonvirtualIntMethodA: ?*anyopaque = null,
    CallNonvirtualLongMethod: ?*anyopaque = null,
    CallNonvirtualLongMethodV: ?*anyopaque = null,
    CallNonvirtualLongMethodA: ?*anyopaque = null,
    CallNonvirtualFloatMethod: ?*anyopaque = null,
    CallNonvirtualFloatMethodV: ?*anyopaque = null,
    CallNonvirtualFloatMethodA: ?*anyopaque = null,
    CallNonvirtualDoubleMethod: ?*anyopaque = null,
    CallNonvirtualDoubleMethodV: ?*anyopaque = null,
    CallNonvirtualDoubleMethodA: ?*anyopaque = null,
    CallNonvirtualVoidMethod: ?*anyopaque = null,
    CallNonvirtualVoidMethodV: ?*anyopaque = null,
    CallNonvirtualVoidMethodA: ?*anyopaque = null,

    GetFieldID: ?*const fn (env: *JNIEnv, clazz: jclass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) jfieldID = null,
    GetObjectField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID) callconv(.c) jobject = null,
    GetBooleanField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID) callconv(.c) jboolean = null,
    GetByteField: ?*anyopaque = null,
    GetCharField: ?*anyopaque = null,
    GetShortField: ?*anyopaque = null,
    GetIntField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID) callconv(.c) jint = null,
    GetLongField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID) callconv(.c) jlong = null,
    GetFloatField: ?*anyopaque = null,
    GetDoubleField: ?*anyopaque = null,

    SetObjectField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID, val: jobject) callconv(.c) void = null,
    SetBooleanField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID, val: jboolean) callconv(.c) void = null,
    SetByteField: ?*anyopaque = null,
    SetCharField: ?*anyopaque = null,
    SetShortField: ?*anyopaque = null,
    SetIntField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID, val: jint) callconv(.c) void = null,
    SetLongField: ?*const fn (env: *JNIEnv, obj: jobject, fieldID: jfieldID, val: jlong) callconv(.c) void = null,
    SetFloatField: ?*anyopaque = null,
    SetDoubleField: ?*anyopaque = null,

    GetStaticMethodID: ?*const fn (env: *JNIEnv, clazz: jclass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) jmethodID = null,
    CallStaticObjectMethod: ?*const fn (env: *JNIEnv, clazz: jclass, methodID: jmethodID, ...) callconv(.c) jobject = null,
    CallStaticObjectMethodV: ?*anyopaque = null,
    CallStaticObjectMethodA: ?*anyopaque = null,
    CallStaticBooleanMethod: ?*const fn (env: *JNIEnv, clazz: jclass, methodID: jmethodID, ...) callconv(.c) jboolean = null,
    CallStaticBooleanMethodV: ?*anyopaque = null,
    CallStaticBooleanMethodA: ?*anyopaque = null,
    CallStaticByteMethod: ?*anyopaque = null,
    CallStaticByteMethodV: ?*anyopaque = null,
    CallStaticByteMethodA: ?*anyopaque = null,
    CallStaticCharMethod: ?*anyopaque = null,
    CallStaticCharMethodV: ?*anyopaque = null,
    CallStaticCharMethodA: ?*anyopaque = null,
    CallStaticShortMethod: ?*anyopaque = null,
    CallStaticShortMethodV: ?*anyopaque = null,
    CallStaticShortMethodA: ?*anyopaque = null,
    CallStaticIntMethod: ?*const fn (env: *JNIEnv, clazz: jclass, methodID: jmethodID, ...) callconv(.c) jint = null,
    CallStaticIntMethodV: ?*anyopaque = null,
    CallStaticIntMethodA: ?*anyopaque = null,
    CallStaticLongMethod: ?*const fn (env: *JNIEnv, clazz: jclass, methodID: jmethodID, ...) callconv(.c) jlong = null,
    CallStaticLongMethodV: ?*anyopaque = null,
    CallStaticLongMethodA: ?*anyopaque = null,
    CallStaticFloatMethod: ?*anyopaque = null,
    CallStaticFloatMethodV: ?*anyopaque = null,
    CallStaticFloatMethodA: ?*anyopaque = null,
    CallStaticDoubleMethod: ?*anyopaque = null,
    CallStaticDoubleMethodV: ?*anyopaque = null,
    CallStaticDoubleMethodA: ?*anyopaque = null,
    CallStaticVoidMethod: ?*const fn (env: *JNIEnv, clazz: jclass, methodID: jmethodID, ...) callconv(.c) void = null,
    CallStaticVoidMethodV: ?*anyopaque = null,
    CallStaticVoidMethodA: ?*anyopaque = null,

    GetStaticFieldID: ?*const fn (env: *JNIEnv, clazz: jclass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) jfieldID = null,
    GetStaticObjectField: ?*const fn (env: *JNIEnv, clazz: jclass, fieldID: jfieldID) callconv(.c) jobject = null,
    GetStaticBooleanField: ?*anyopaque = null,
    GetStaticByteField: ?*anyopaque = null,
    GetStaticCharField: ?*anyopaque = null,
    GetStaticShortField: ?*anyopaque = null,
    GetStaticIntField: ?*anyopaque = null,
    GetStaticLongField: ?*anyopaque = null,
    GetStaticFloatField: ?*anyopaque = null,
    GetStaticDoubleField: ?*anyopaque = null,

    SetStaticObjectField: ?*anyopaque = null,
    SetStaticBooleanField: ?*anyopaque = null,
    SetStaticByteField: ?*anyopaque = null,
    SetStaticCharField: ?*anyopaque = null,
    SetStaticShortField: ?*anyopaque = null,
    SetStaticIntField: ?*anyopaque = null,
    SetStaticLongField: ?*anyopaque = null,
    SetStaticFloatField: ?*anyopaque = null,
    SetStaticDoubleField: ?*anyopaque = null,

    NewString: ?*anyopaque = null,
    GetStringLength: ?*anyopaque = null,
    GetStringChars: ?*anyopaque = null,
    ReleaseStringChars: ?*anyopaque = null,
    NewStringUTF: ?*const fn (env: *JNIEnv, bytes: [*:0]const u8) callconv(.c) jstring = null,
    GetStringUTFLength: ?*anyopaque = null,
    GetStringUTFChars: ?*const fn (env: *JNIEnv, string: jstring, isCopy: ?*jboolean) callconv(.c) ?[*:0]const u8 = null,
    ReleaseStringUTFChars: ?*const fn (env: *JNIEnv, string: jstring, utf: [*:0]const u8) callconv(.c) void = null,
    GetArrayLength: ?*const fn (env: *JNIEnv, array: jobject) callconv(.c) jsize = null,
    NewObjectArray: ?*const fn (env: *JNIEnv, length: jsize, elementClass: jclass, initialElement: jobject) callconv(.c) jobject = null,
    GetObjectArrayElement: ?*anyopaque = null,
    SetObjectArrayElement: ?*anyopaque = null,
    NewBooleanArray: ?*anyopaque = null,
    NewByteArray: ?*anyopaque = null,
    NewCharArray: ?*anyopaque = null,
    NewShortArray: ?*anyopaque = null,
    NewIntArray: ?*anyopaque = null,
    NewLongArray: ?*anyopaque = null,
    NewFloatArray: ?*anyopaque = null,
    NewDoubleArray: ?*anyopaque = null,

    GetBooleanArrayElements: ?*anyopaque = null,
    GetByteArrayElements: ?*const fn (env: *JNIEnv, array: jobject, isCopy: ?*jboolean) callconv(.c) ?[*]jbyte = null,
    GetCharArrayElements: ?*anyopaque = null,
    GetShortArrayElements: ?*anyopaque = null,
    GetIntArrayElements: ?*anyopaque = null,
    GetLongArrayElements: ?*anyopaque = null,
    GetFloatArrayElements: ?*anyopaque = null,
    GetDoubleArrayElements: ?*anyopaque = null,

    ReleaseBooleanArrayElements: ?*anyopaque = null,
    ReleaseByteArrayElements: ?*const fn (env: *JNIEnv, array: jobject, elems: [*]jbyte, mode: jint) callconv(.c) void = null,
    ReleaseCharArrayElements: ?*anyopaque = null,
    ReleaseShortArrayElements: ?*anyopaque = null,
    ReleaseIntArrayElements: ?*anyopaque = null,
    ReleaseLongArrayElements: ?*anyopaque = null,
    ReleaseFloatArrayElements: ?*anyopaque = null,
    ReleaseDoubleArrayElements: ?*anyopaque = null,

    GetBooleanArrayRegion: ?*anyopaque = null,
    GetByteArrayRegion: ?*const fn (env: *JNIEnv, array: jobject, start: jsize, len: jsize, buf: [*]jbyte) callconv(.c) void = null,
    GetCharArrayRegion: ?*anyopaque = null,
    GetShortArrayRegion: ?*anyopaque = null,
    GetIntArrayRegion: ?*anyopaque = null,
    GetLongArrayRegion: ?*anyopaque = null,
    GetFloatArrayRegion: ?*anyopaque = null,
    GetDoubleArrayRegion: ?*anyopaque = null,

    SetBooleanArrayRegion: ?*anyopaque = null,
    SetByteArrayRegion: ?*anyopaque = null,
    SetCharArrayRegion: ?*anyopaque = null,
    SetShortArrayRegion: ?*anyopaque = null,
    SetIntArrayRegion: ?*anyopaque = null,
    SetLongArrayRegion: ?*anyopaque = null,
    SetFloatArrayRegion: ?*anyopaque = null,
    SetDoubleArrayRegion: ?*anyopaque = null,

    RegisterNatives: ?*anyopaque = null,
    UnregisterNatives: ?*anyopaque = null,
    MonitorEnter: ?*anyopaque = null,
    MonitorExit: ?*anyopaque = null,
    GetJavaVM: ?*const fn (env: *JNIEnv, vm: *?*JavaVM) callconv(.c) jint = null,
};

pub const JNIEnv = *const JNINativeInterface;

pub const JNIInvokeInterface = extern struct {
    reserved0: ?*anyopaque = null,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,

    DestroyJavaVM: ?*anyopaque = null,
    AttachCurrentThread: ?*const fn (vm: *JavaVM, penv: *?*anyopaque, args: ?*anyopaque) callconv(.c) jint = null,
    DetachCurrentThread: ?*anyopaque = null,
    GetEnv: ?*const fn (vm: *JavaVM, penv: *?*anyopaque, version: jint) callconv(.c) jint = null,
    AttachCurrentThreadAsDaemon: ?*anyopaque = null,
};

pub const JavaVM = *const JNIInvokeInterface;

// ============================================================================
// Утилиты получения JNIEnv из jvm.dll в текущем потоке
// ============================================================================

const win32 = struct {
    extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
};

var cached_jvm: ?*JavaVM = null;
var cached_class_loader: ?jobject = null;

pub fn getJniEnv() ?*JNIEnv {
    if (cached_jvm) |vm| {
        var env_ptr: ?*anyopaque = null;
        if (vm.*.GetEnv) |get_env| {
            if (get_env(vm, &env_ptr, 0x00010008) == 0 and env_ptr != null) {
                return @ptrCast(@alignCast(env_ptr));
            }
        }
        if (vm.*.AttachCurrentThread) |attach| {
            if (attach(vm, &env_ptr, null) == 0 and env_ptr != null) {
                return @ptrCast(@alignCast(env_ptr));
            }
        }
    }
    const h_jvm = win32.GetModuleHandleA("jvm.dll") orelse return null;
    const proc = win32.GetProcAddress(h_jvm, "JNI_GetCreatedJavaVMs") orelse return null;
    const get_vms_fn: *const fn (vmBuf: [*]?*JavaVM, bufLen: jsize, nVMs: *jsize) callconv(.c) jint = @ptrCast(proc);
    var vms: [1]?*JavaVM = [_]?*JavaVM{null};
    var n_vms: jsize = 0;
    if (get_vms_fn(&vms, 1, &n_vms) == 0 and n_vms > 0 and vms[0] != null) {
        cached_jvm = vms[0];
        return getJniEnv();
    }
    return null;
}

pub fn getAppClassLoader(env: *JNIEnv) ?jobject {
    if (cached_class_loader) |loader| return loader;

    // 1. Thread.currentThread().getContextClassLoader()
    if (env.*.FindClass) |find_cls| {
        const thread_cls = find_cls(env, "java/lang/Thread");
        if (thread_cls != null) {
            defer if (env.*.DeleteLocalRef) |del| del(env, thread_cls.?);
            if (env.*.GetStaticMethodID) |get_smid| {
                const cur_mid = get_smid(env, thread_cls.?, "currentThread", "()Ljava/lang/Thread;");
                if (cur_mid != null and env.*.CallStaticObjectMethod != null) {
                    const cur_thread = env.*.CallStaticObjectMethod.?(env, thread_cls.?, cur_mid.?);
                    if (cur_thread != null) {
                        defer if (env.*.DeleteLocalRef) |del| del(env, cur_thread.?);
                        if (env.*.GetMethodID) |get_mid| {
                            const get_ccl_mid = get_mid(env, thread_cls.?, "getContextClassLoader", "()Ljava/lang/ClassLoader;");
                            if (get_ccl_mid != null and env.*.CallObjectMethod != null) {
                                const ccl = env.*.CallObjectMethod.?(env, cur_thread.?, get_ccl_mid.?);
                                if (ccl != null) {
                                    const gref = if (env.*.NewGlobalRef) |ng| ng(env, ccl) else ccl;
                                    cached_class_loader = gref;
                                    return gref;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (env.*.ExceptionClear) |c| c(env);

    // 2. ClassLoader.getSystemClassLoader()
    if (env.*.FindClass) |find_cls| {
        const cl_cls = find_cls(env, "java/lang/ClassLoader");
        if (cl_cls != null) {
            defer if (env.*.DeleteLocalRef) |del| del(env, cl_cls.?);
            if (env.*.GetStaticMethodID) |get_smid| {
                const get_sys_mid = get_smid(env, cl_cls.?, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
                if (get_sys_mid != null and env.*.CallStaticObjectMethod != null) {
                    const sys_loader = env.*.CallStaticObjectMethod.?(env, cl_cls.?, get_sys_mid.?);
                    if (sys_loader != null) {
                        const gref = if (env.*.NewGlobalRef) |ng| ng(env, sys_loader) else sys_loader;
                        cached_class_loader = gref;
                        return gref;
                    }
                }
            }
        }
    }
    if (env.*.ExceptionClear) |c| c(env);
    return null;
}

pub fn loadClassWithLoader(env: *JNIEnv, loader: ?jobject, name_slashed: [*:0]const u8) ?jclass {
    // 1. Try FindClass first
    if (env.*.FindClass) |f| {
        const cls = f(env, name_slashed);
        if (cls != null) return cls;
    }
    if (env.*.ExceptionClear) |c| c(env);

    // 2. Use the provided loader or fall back to cached AppClassLoader
    const ldr = loader orelse getAppClassLoader(env) orelse return null;

    var dotted_buf: [256]u8 = undefined;
    var i: usize = 0;
    while (name_slashed[i] != 0 and i < dotted_buf.len - 1) : (i += 1) {
        dotted_buf[i] = if (name_slashed[i] == '/') '.' else name_slashed[i];
    }
    dotted_buf[i] = 0;

    const loader_cls = if (env.*.GetObjectClass) |goc| goc(env, ldr) else null;
    if (loader_cls == null) {
        if (env.*.ExceptionClear) |c| c(env);
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, loader_cls.?);

    const mid = if (env.*.GetMethodID) |gmid|
        gmid(env, loader_cls.?, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
    else null;
    if (mid == null) {
        if (env.*.ExceptionClear) |c| c(env);
        return null;
    }

    const jname = if (env.*.NewStringUTF) |ns| ns(env, dotted_buf[0..i :0]) else null;
    if (jname == null) {
        if (env.*.ExceptionClear) |c| c(env);
        return null;
    }
    defer if (env.*.DeleteLocalRef) |del| del(env, jname.?);

    const res = if (env.*.CallObjectMethod) |com| com(env, ldr, mid.?, jname.?) else null;
    if (env.*.ExceptionClear) |c| c(env);
    return res;
}

pub fn toJniObject(env: *JNIEnv, handle_ptr: ?*anyopaque) jobject {
    if (handle_ptr == null) return null;
    const scope_cls = loadClassWithLoader(env, null, "com/mandagram/plugin/bridge/ObjectHandleScope") orelse return null;
    defer if (env.*.DeleteLocalRef) |del| del(env, scope_cls);

    const mid = if (env.*.GetStaticMethodID) |gsm|
        gsm(env, scope_cls, "getObject", "(J)Ljava/lang/Object;")
    else null;
    if (mid == null) {
        if (env.*.ExceptionClear) |c| c(env);
        return null;
    }

    const h_long: jlong = @intCast(@intFromPtr(handle_ptr));
    const real_obj = if (env.*.CallStaticObjectMethod) |csm|
        csm(env, scope_cls, mid.?, h_long)
    else null;
    if (env.*.ExceptionClear) |c| c(env);
    return real_obj;
}

// ============================================================================
