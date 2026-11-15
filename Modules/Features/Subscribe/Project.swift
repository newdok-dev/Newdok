import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.feature(
    name: "Subscribe",
    interfaceDependencies: [.shared],
    dataDependencies: [],
    featureDependencies: [.featureData("Subscribe"), .networkKit, .composableArchitecture],
    testDependencies: [.composableArchitecture],
    exampleDependencies: [.composableArchitecture],
    hasInterface: true,
    hasExample: true
)
