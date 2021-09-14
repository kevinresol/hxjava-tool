package;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.lang.Runtime;
import java.NativeArray;
import java.nio.file.attribute.PosixFilePermissions;
import java.nio.file.CopyOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.StdTypes.Int8;
import org.apache.commons.compress.archivers.ArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import sys.thread.FixedThreadPool;
import sys.thread.Lock;
import sys.thread.Mutex;

using StringTools;

class Main {
	static final URLS = [
		// https://jdk.java.net/archive/
		16 => 'https://download.java.net/java/GA/jdk16/7863447f0ab643c585b9bdebf67c69db/36/GPL/openjdk-16_osx-x64_bin.tar.gz',
		15 => 'https://download.java.net/java/GA/jdk15.0.2/0d1cfde4252546c6931946de8db48ee2/7/GPL/openjdk-15.0.2_osx-x64_bin.tar.gz',
		14 => 'https://download.java.net/java/GA/jdk14.0.2/205943a0976c4ed48cb16f1043c5c647/12/GPL/openjdk-14.0.2_osx-x64_bin.tar.gz',
		13 => 'https://download.java.net/java/GA/jdk13.0.2/d4173c853231432d94f001e99d882ca7/8/GPL/openjdk-13.0.2_osx-x64_bin.tar.gz',
		12 => 'https://download.java.net/java/GA/jdk12.0.2/e482c34c86bd4bf8b56c0b35558996b9/10/GPL/openjdk-12.0.2_osx-x64_bin.tar.gz',
		11 => 'https://download.java.net/java/GA/jdk11/9/GPL/openjdk-11.0.2_osx-x64_bin.tar.gz',
		10 => 'https://download.java.net/java/GA/jdk10/10.0.2/19aef61b38124481863b1413dce1855f/13/openjdk-10.0.2_osx-x64_bin.tar.gz',
		9 => 'https://download.java.net/java/GA/jdk9/9.0.4/binaries/openjdk-9.0.4_osx-x64_bin.tar.gz',
	];
	
	static final downloader = new Mutex();

	static function main() {
		final pool = new FixedThreadPool(Runtime.getRuntime().availableProcessors());
		final lock = new Lock();
		for (version in URLS.keys())
			pool.run(() -> {
				try new Main(version) catch(e) trace(e);
				lock.release();
			});
		for (version in URLS.keys())
			lock.wait();
		Sys.println('end');
	}

	final version:Int;
	final folder:String;

	function new(version:Int) {
		this.version = version;
		final url = URLS[version];
		folder = 'out/jdk$version';

		downloader.acquire();
		final stream = download(url);
		final jdk = untgz(stream);
		downloader.release();
		
		// final jdk = Paths.get('$folder/jdk');
		final modules = extractModules(jdk);
		// final modules = Paths.get('$folder/modules');
		final rewritten = rewrite(modules);
		final packed = pack(rewritten);
		trace(packed);
	}

	function download(url:String) {
		log('Download jdk');
		return new java.net.URL(url).openConnection().getInputStream();
	}

	function untgz(stream:InputStream):Path {
		final output = Paths.get('$folder/jdk');
		final tarStream = new TarArchiveInputStream(new GzipCompressorInputStream(new BufferedInputStream(stream)));

		inline function zipSlipProtect(entry:ArchiveEntry, targetDir:Path) {
			final normalizePath = targetDir.resolve(entry.getName()).normalize();
			if (!normalizePath.startsWith(targetDir)) {
				throw new IOException(' The compressed file has been damaged : ' + entry.getName());
			}
			return normalizePath;
		}

		log('Untar jdk');
		var entry;
		while ((entry = tarStream.getNextEntry()) != null) {
			// Get the unzip file directory , And determine whether the file is damaged
			final newPath = zipSlipProtect(entry, output);
			if (entry.isDirectory()) {
				// Create a directory for extracting files
				Files.createDirectories(newPath);
			} else {
				// Verify the existence of the extracted file directory again
				final parent = newPath.getParent();
				if (parent != null)
					if (Files.notExists(parent))
						Files.createDirectories(parent);

				// Input the extracted file into TarArchiveInputStream, Output to disk newPath Catalog
				Files.copy(tarStream, newPath, (cast StandardCopyOption.REPLACE_EXISTING : CopyOption));
			}
		}

		return output;
	}

	function extractModules(jdk:Path) {
		final jimage = findFile(jdk, 'jimage');
		final modules = findFile(jdk, 'modules');
		final output = Paths.get('$folder/modules');

		log(jimage.toString());
		log(modules.toString());
		log(output.toString());
		
		Files.setPosixFilePermissions(jimage, PosixFilePermissions.fromString('rwxr--r--'));
		Sys.command(jimage.toString(), ['extract', '--dir', output.toString(), modules.toString()]);

		return output.toAbsolutePath();
	}

	function rewrite(modules:Path) {
		final temp = modules.resolve('../interim').normalize();
		final prefix = temp.toString();

		log('Rewrite modules in ${modules.toString()}');
		(function process(dir:File) {
			for (file in dir.listFiles()) {
				if (file.isFile()) {
					final path = file.toPath();
					if (path.toString().endsWith('.class') && path.getFileName().toString() != 'module-info.class') {
						// log('Process $path ');
						final obj:NativeArray<Int8> = Files.readAllBytes(path);
						final reader = new ClassReader(obj);
						final writer = new ClassWriter(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
						final visitor = new CustomClassVisitor(version <= 14 ? Opcodes.ASM7 : version <= 15 ? Opcodes.ASM8 : Opcodes.ASM9, writer);

						reader.accept(visitor, 0);

						final parts = path.normalize().toString().substr(prefix.length + 1).split('/');
						final dst = temp.resolve((parts[0].indexOf('.') != -1 ? parts.slice(1) : parts).join('/'));
						final folder = dst.getParent().toFile();
						if (!folder.exists())
							folder.mkdirs();
						new FileOutputStream(dst.toFile()).write(writer.toByteArray());
					}
				} else {
					// log('Process sub folder ${file.toPath().toString()}');
					process(file);
				}
			}
		})(modules.toFile());

		return temp.toAbsolutePath();
	}

	function pack(classes:Path) {
		final out = '$folder/hxjava-std.jar';
		log('Pack jar');
		if (Sys.command('jar', ['cf', out, '-C', classes.toString(), '.']) == 0) {
			log('Done!');
		} else {
			log('Oops, something went wrong.');
		}

		return Paths.get(out).toAbsolutePath();
	}

	// Utils

	function findFile(folder:Path, filename:String):Path {
		var ret = null;
		(function findIn(dir:File) {
			for (file in dir.listFiles()) {
				if (file.isDirectory())
					findIn(file);
				else if (file.getName() == filename) {
					ret = file.toPath().toAbsolutePath();
					break;
				}
			}
		})(folder.toFile());
		return ret;
	}

	inline function log(v:String) {
		Sys.println('jdk$version: $v');
	}
}

class CustomClassVisitor extends ClassVisitor {
	
	final ver:Int;
	
	public function new(ver, visitor:ClassVisitor) {
		super(this.ver = ver, visitor);
	}

	@:overload
	override function visit(version:Int, access:Int, name:String, signature:String, superName:String, interfaces:NativeArray<String>):Void {
		cv.visit(version, access, name, signature, superName, interfaces);
	}

	/**
	 * Starts the visit of the method's code, if any (i.e. non abstract method).
	 */
	@:overload
	override function visitMethod(access:Int, name:String, desc:String, signature:String, exceptions:NativeArray<String>):MethodVisitor {
		final mv:MethodVisitor = cv.visitMethod(access, name, desc, signature, exceptions);
		if (mv != null) {
			return new CustomMethodVisitor(ver, mv);
		}
		return mv;
	}
}

class CustomMethodVisitor extends MethodVisitor {
	final target:MethodVisitor;

	public function new(ver, target:MethodVisitor) {
		super(ver, null);
		this.target = target;
	}

	@:overload
	override function visitCode() {
		target.visitCode();
		target.visitMaxs(0, 0);
		target.visitEnd();
	}
}
