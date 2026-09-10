#ifndef DUMMY_MODULE_GENERATOR_H
#define DUMMY_MODULE_GENERATOR_H

#include <QString>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QVector>
#include <cstdlib>

struct DummyModule {
    QString name;
    QString path;
};

class DummyModuleGenerator {
public:
    static QVector<DummyModule> generate(int count, const QString& outputDir) {
        QString templatePath = findTemplate();
        if (templatePath.isEmpty()) return {};

        QFile templateFile(templatePath);
        if (!templateFile.open(QIODevice::ReadOnly)) return {};
        QByteArray templateData = templateFile.readAll();
        templateFile.close();

        QDir().mkpath(outputDir);

        QString ext = QFileInfo(templatePath).suffix();
        if (!ext.isEmpty()) ext.prepend('.');

        static const QString kTemplateName = QStringLiteral("dummy_module_000000");

        if (!templateData.contains(kTemplateName.toUtf8())) {
            qWarning("DummyModuleGenerator: template binary does not contain marker '%s' — "
                     "binary patching will not work", qUtf8Printable(kTemplateName));
            return {};
        }

        QVector<DummyModule> result;
        result.reserve(count);

        for (int i = 0; i < count; ++i) {
            QString moduleName = QString("dummy_module_%1").arg(i, 6, 10, QChar('0'));

            QByteArray patched = templateData;
            patched.replace(kTemplateName.toUtf8(), moduleName.toUtf8());
            // AND the UTF-16 copy. The module's self-asserted identity —
            // PluginInterface::name(), which the host compares against the name
            // it loaded the file as — is emitted as a QStringLiteral, so it
            // sits in the binary as UTF-16 while the plugin METADATA the
            // registry reads is UTF-8. Patch only the UTF-8 and every generated
            // module registers under its own name and then introduces itself as
            // dummy_module_000000: "plugin name mismatch", every load refused.
            patched.replace(utf16(kTemplateName), utf16(moduleName));

            QString filePath = QDir(outputDir).absoluteFilePath(
                QString("lib%1_plugin%2").arg(moduleName, ext));

            QFile out(filePath);
            if (!out.open(QIODevice::WriteOnly)) return {};
            out.write(patched);
            out.close();

            QFile::setPermissions(filePath,
                QFileDevice::ReadOwner  | QFileDevice::WriteOwner | QFileDevice::ExeOwner |
                QFileDevice::ReadGroup  | QFileDevice::ExeGroup |
                QFileDevice::ReadOther  | QFileDevice::ExeOther);

            // A patched image has to be made loadable again before it is
            // handed out; see reSign(). Fatal rather than an empty return:
            // an empty one reads as "no template here" and SKIPS the whole
            // fixture, which is how a fixture stops testing anything without
            // anyone noticing.
            if (!reSign(filePath))
                qFatal("DummyModuleGenerator: could not re-sign %s",
                       qUtf8Printable(filePath));

            result.append({moduleName, filePath});
        }

        return result;
    }

private:
    // Little-endian UTF-16 bytes, no BOM and no terminator — the shape
    // QStringLiteral leaves in the binary.
    static QByteArray utf16(const QString& s) {
        QByteArray out;
        out.reserve(s.size() * 2);
        for (QChar c : s) {
            const ushort u = c.unicode();
            out.append(static_cast<char>(u & 0xff));
            out.append(static_cast<char>(u >> 8));
        }
        return out;
    }

    // THE PATCH BREAKS THE SIGNATURE, and on arm64 macOS that is fatal rather
    // than cosmetic: every Mach-O carries at least an ad-hoc signature, the
    // kernel validates each page as it is faulted in, and a page whose hash no
    // longer matches kills the process outright — SIGKILL, CODESIGNING/Invalid
    // Page, no chance to report anything. So a host that dlopen'd one of these
    // died before it could say why, and the only module that ever loaded was
    // dummy_module_000000, whose "patch" replaces its own name with itself and
    // therefore leaves the bytes alone.
    //
    // Re-signing ad hoc (`--sign -`) recomputes those hashes. It grants no
    // entitlement and asks for no identity, which is all a test fixture needs.
    // Nothing to do anywhere else: ELF has no such check, so on Linux the
    // patched copy was always loadable.
    static bool reSign(const QString& path) {
#ifdef Q_OS_DARWIN
        QString tool = QString::fromLocal8Bit(qgetenv("LOGOS_CODESIGN"));
#ifdef LOGOS_CODESIGN
        if (tool.isEmpty()) tool = QStringLiteral(LOGOS_CODESIGN);
#endif
        if (tool.isEmpty()) {
            qWarning("DummyModuleGenerator: no codesign tool (LOGOS_CODESIGN); "
                     "the patched module would be SIGKILLed on load");
            return false;
        }
        QProcess p;
        p.start(tool, {QStringLiteral("--force"), QStringLiteral("--sign"),
                       QStringLiteral("-"), path});
        if (!p.waitForFinished(60000)) {
            p.kill();
            qWarning("DummyModuleGenerator: %s timed out signing %s",
                     qUtf8Printable(tool), qUtf8Printable(path));
            return false;
        }
        if (p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
            qWarning("DummyModuleGenerator: %s failed on %s: %s",
                     qUtf8Printable(tool), qUtf8Printable(path),
                     p.readAllStandardError().constData());
            return false;
        }
#else
        Q_UNUSED(path);
#endif
        return true;
    }

    static QString findTemplate() {
        const char* env = std::getenv("DUMMY_PLUGIN_TEMPLATE_DIR");
        if (env && env[0]) return findIn(QString::fromUtf8(env));

#ifdef DUMMY_PLUGIN_TEMPLATE_DIR
        QString fromDefine = findIn(QString(DUMMY_PLUGIN_TEMPLATE_DIR));
        if (!fromDefine.isEmpty()) return fromDefine;
#endif
        return {};
    }

    static QString findIn(const QString& dir) {
        QDir d(dir);
        for (const QFileInfo& fi : d.entryInfoList(QDir::Files)) {
            const QString fn = fi.fileName();
            if (fn.startsWith("dummy_module_000000_plugin") ||
                fn.startsWith("libdummy_module_000000_plugin"))
                return fi.absoluteFilePath();
        }
        return {};
    }
};

#endif // DUMMY_MODULE_GENERATOR_H
