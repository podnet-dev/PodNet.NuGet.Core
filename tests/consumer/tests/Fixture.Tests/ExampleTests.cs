using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Fixture.Tests;

[TestClass]
public class ExampleTests
{
    [TestMethod]
    public void ValueIsExpected() => Assert.AreEqual(42, Example.Value);
}