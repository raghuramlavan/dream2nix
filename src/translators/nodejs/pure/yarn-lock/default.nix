{
  lib,

  externals,
  translatorName,
  utils,
  ...
}:

{
  translate =
    {
      inputDirectories,
      inputFiles,

      # extraArgs
      dev,
      optional,
      peer,
      ...
    }:
    let
      b = builtins;
      yarnLock = utils.readTextFile "${lib.elemAt inputDirectories 0}/yarn.lock";
      packageJSON = b.fromJSON (b.readFile "${lib.elemAt inputDirectories 0}/package.json");
      parser = import ./parser.nix { inherit lib; inherit (externals) nix-parsec;};
      tryParse = parser.parseLock yarnLock;

      mainPackageName = packageJSON.name;
      mainPackageKey = "${mainPackageName}#${packageJSON.version}";
      
      parsedLock =
        if tryParse.type == "success" then
          lib.foldAttrs (n: a: n // a) {} tryParse.value
        else
          let
            failureOffset = tryParse.value.offset;
          in
            throw "parser failed at: \n${lib.substring failureOffset 50 tryParse.value.str}";
      nameFromLockName = lockName:
        let
          version = lib.last (lib.splitString "@" lockName);
        in
          lib.removeSuffix "@${version}" lockName;
      sources = lib.mapAttrs' (dependencyName: dependencyAttrs:
        let
          name = nameFromLockName dependencyName;
        in
          lib.nameValuePair ("${name}#${dependencyAttrs.version}") (
          if lib.hasInfix "@github:" dependencyName
              || lib.hasInfix "codeload.github.com/" dependencyAttrs.resolved then
            let
               gitUrlInfos = lib.splitString "/" dependencyAttrs.resolved;
            in
            {
              type = "github";
              rev = lib.elemAt gitUrlInfos 6;
              owner = lib.elemAt gitUrlInfos 3;
              repo = lib.elemAt gitUrlInfos 4;
            }
          else if lib.hasInfix "@link:" dependencyName then
            {
              version = dependencyAttrs.version;     
              path = lib.last (lib.splitString "@link:" dependencyName);
              type = "path";
            }
          else
            {
              version = dependencyAttrs.version;  
              hash =
                if dependencyAttrs ? integrity then
                  dependencyAttrs.integrity
                else
                  throw "Missing integrity for ${dependencyName}";
              url = lib.head (lib.splitString "#" dependencyAttrs.resolved);
              type = "fetchurl";
            }
          )) parsedLock;
      dependencyGraph =
        (lib.mapAttrs'
          (dependencyName: dependencyAttrs:
            let
              name = nameFromLockName dependencyName;
              dependencies = 
                dependencyAttrs.dependencies or []
                ++ (lib.optionals optional (dependencyAttrs.optionalDependencies or []));
              graph = lib.forEach dependencies (dependency:
                builtins.head (
                  lib.mapAttrsToList
                    (name: value:
                      let
                        yarnName = "${name}@${value}";
                        version = parsedLock."${yarnName}".version;
                      in
                      "${name}#${version}"
                    )
                    dependency
                )
              );
            in
              lib.nameValuePair ("${name}#${dependencyAttrs.version}") graph
          )
          parsedLock
        )
        //
        {
          "${mainPackageName}" =
            lib.mapAttrsToList
              (depName: depSemVer:
                let
                  depYarnKey = "${depName}@${depSemVer}";
                  dependencyAttrs =
                    if ! parsedLock ? "${depYarnKey}" then
                      throw "Cannot find entry for top level dependency: '${depYarnKey}'"
                    else
                      parsedLock."${depYarnKey}";
                in
                  "${depName}#${dependencyAttrs.version}"
              )
              (
                packageJSON.dependencies or {}
                //
                (lib.optionalAttrs dev (packageJSON.devDependencies or {}))
                //
                (lib.optionalAttrs peer (packageJSON.peerDependencies or {}))
              );
        };


    in
    # TODO: produce dream lock like in /specifications/dream-lock-example.json
      
    rec {
      inherit sources;

      generic = {
        buildSystem = "nodejs";
        producedBy = translatorName;
        mainPackage = mainPackageName;
        inherit dependencyGraph;
        sourcesCombinedHash = null;
      };

      # build system specific attributes
      buildSystem = {

        # example
        nodejsVersion = 14;
      };
    };
      

  # From a given list of paths, this function returns all paths which can be processed by this translator.
  # This allows the framework to detect if the translator is compatible with the given inputs
  # to automatically select the right translator.
  compatiblePaths =
    {
      inputDirectories,
      inputFiles,
    }@args:
    {
      inputDirectories = lib.filter 
        (utils.containsMatchingFile [ ''.*yarn\.lock'' ''.*package.json'' ])
        args.inputDirectories;

      inputFiles = [];
    };


  # If the translator requires additional arguments, specify them here.
  # There are only two types of arguments:
  #   - string argument (type = "argument")
  #   - boolean flag (type = "flag")
  # String arguments contain a default value and examples. Flags do not.
  specialArgs = {

    dev = {
      description = "Whether to include development dependencies";
      type = "flag";
    };

    optional = {
      description = "Whether to include optional dependencies";
      type = "flag";
    };

    peer = {
      description = "Whether to include peer dependencies";
      type = "flag";
    };

  };
}
